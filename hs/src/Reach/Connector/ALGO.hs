module Reach.Connector.ALGO (connect_algo, AlgoError (..)) where

import Control.Monad.Extra
import Control.Monad.Reader
import Crypto.Hash
import qualified Data.Aeson as Aeson
import Data.Bits (shiftL, (.|.))
import qualified Data.ByteArray as BA
import qualified Data.ByteString as BS
import Data.ByteString.Base64 (encodeBase64')
import Data.ByteString.Builder
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Internal as BI
import qualified Data.ByteString.Lazy as LB
import qualified Data.DList as DL
import Data.Function
import qualified Data.HashMap.Strict as HM
import Data.IORef
import Data.List (intercalate)
import qualified Data.List as List
import qualified Data.Map.Strict as M
import Data.Maybe
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.Lazy as LT
import qualified Data.Vector as Vector
import Data.Word
import Generics.Deriving (Generic)
import Reach.AST.Base
import Reach.AST.DLBase
import Reach.AST.PL
import Reach.BinaryLeafTree
import Reach.CommandLine
import Reach.Connector
import Reach.Counter
import Reach.FixedPoint
import Reach.Texty (pretty)
import Reach.UnsafeUtil
import Reach.Util
import Reach.Warning
import Safe (atMay)
import System.Exit
import System.FilePath
import System.IO.Temp
import System.Process.ByteString

-- Errors for ALGO

data AlgoError
  = Err_TransferNewToken
  | Err_PayNewToken
  deriving (Eq, ErrorMessageForJson, ErrorSuggestions, Generic)

instance HasErrorCode AlgoError where
  errPrefix = const "RA"
  errIndex = \case
    Err_TransferNewToken {} -> 0
    Err_PayNewToken {} -> 1

instance Show AlgoError where
  show = \case
    Err_TransferNewToken ->
      "Token cannot be transferred within the same consensus step it was created in on Algorand"
    Err_PayNewToken ->
      "Token cannot be paid within the same consensus step it was shared with the contract on Algorand"

-- General tools that could be elsewhere

type LPGraph a = M.Map a (M.Map a Integer)

type LPPath a = (String, [(a, Integer)], Integer)

type LPInt a = M.Map a ([(a, Integer)], Integer)

longestPathBetween :: forall a. (Ord a, Monoid a, Show a) => LPGraph a -> a -> a -> IO (LPPath a)
longestPathBetween g f _d = do
  let r x y = fromMaybe ([], 0) $ M.lookup x y
  ps <- fixedPoint $ \_ (m :: LPInt a) -> do
    flip mapWithKeyM g $ \n cs -> do
      cs' <- flip mapM (M.toAscList cs) $ \(t, c) -> do
        let (p, pc) = r t m
        let p' = (t, c) : p
        let c' = pc + c
        case n `elem` map fst p' of
          True -> return (p, -1)
          False -> return (p', c')
      return $ List.maximumBy (compare `on` snd) cs'
  let (p, pc) = r f ps
  let mkEdges s from = \case
        [] -> s
        (to, _) : m -> mkEdges (S.insert (from, to) s) to m
  let edges = mkEdges mempty f p
  let edge = flip S.member edges
  let gs_body =
        flip concatMap (M.toAscList g) $ \(from, cs) ->
          flip concatMap (M.toAscList cs) $ \(to, c) ->
            case (from == mempty) of
              True -> ""
              False -> show from <> " -> " <> show to <> " [label=\"" <> show c <> "\"" <> (if edge (from, to) then ",color=red" else "") <> "];\n"
  let gs = "digraph {\n" <> gs_body <> "}"
  return $ (gs, p, pc)

aarray :: [Aeson.Value] -> Aeson.Value
aarray = Aeson.Array . Vector.fromList

aobject :: M.Map T.Text Aeson.Value -> Aeson.Value
aobject = Aeson.Object . HM.fromList . M.toList

-- Algorand constants

conName' :: T.Text
conName' = "ALGO"

conCons' :: DLConstant -> DLLiteral
conCons' DLC_UInt_max = DLL_Int sb $ 2 ^ (64 :: Integer) - 1

algoMinTxnFee :: Integer
algoMinTxnFee = 1000

algoMaxLocalSchemaEntries :: Integer
algoMaxLocalSchemaEntries = 16

algoMaxLocalSchemaEntries_usable :: Integer
algoMaxLocalSchemaEntries_usable = algoMaxLocalSchemaEntries

algoMaxGlobalSchemaEntries :: Integer
algoMaxGlobalSchemaEntries = 64

algoMaxGlobalSchemaEntries_usable :: Integer
algoMaxGlobalSchemaEntries_usable = algoMaxGlobalSchemaEntries - 1

algoMaxAppBytesValueLen :: Integer
algoMaxAppBytesValueLen = 128

algoMaxAppBytesValueLen_usable :: Integer
algoMaxAppBytesValueLen_usable =
  -- We guarantee that every key is exactly one byte, so all the rest of the
  -- space goes to the value
  algoMaxAppBytesValueLen - 1

algoMaxAppTotalArgLen :: Integer
algoMaxAppTotalArgLen = 2048

algoMinimumBalance :: Integer
algoMinimumBalance = 100000

algoMaxTxGroupSize :: Integer
algoMaxTxGroupSize = 16

algoMaxInnerTransactions :: Integer
algoMaxInnerTransactions = 16

algoMaxAppTxnAccounts :: Integer
algoMaxAppTxnAccounts = 4

algoMaxAppTxnForeignAssets :: Integer
algoMaxAppTxnForeignAssets = 8

algoMaxAppProgramCost :: Integer
algoMaxAppProgramCost = 700

-- We're making up this name. It is not in consensus.go, but only in the docs
algoMaxLogLen :: Integer
algoMaxLogLen = 1024

algoMaxAppProgramLen :: Integer
algoMaxAppProgramLen = 2048

algoMaxExtraAppProgramPages :: Integer
algoMaxExtraAppProgramPages = 3

algoMaxAppProgramLen_really :: Integer
algoMaxAppProgramLen_really = (1 + algoMaxExtraAppProgramPages) * algoMaxAppProgramLen

minimumBalance_l :: DLLiteral
minimumBalance_l = DLL_Int sb algoMinimumBalance

tealVersionPragma :: LT.Text
tealVersionPragma = "#pragma version 5"

-- Algo specific stuff

maxTypeSize :: M.Map a DLType -> Integer
maxTypeSize m =
  case M.null m of
    True -> 0
    False -> maximum $ map typeSizeOf $ M.elems m

typeSig :: DLType -> String
typeSig x =
  case x of
    T_Null -> "byte[0]"
    T_Bool -> "byte" -- "bool"
    T_UInt -> "uint64"
    T_Bytes sz -> "byte" <> array sz
    T_Digest -> "digest"
    T_Address -> "address"
    T_Contract -> typeSig T_UInt
    T_Token -> typeSig T_UInt
    T_Array t sz -> typeSig t <> array sz
    T_Tuple ts -> "(" <> intercalate "," (map typeSig ts) <> ")"
    T_Object m -> typeSig $ T_Tuple $ M.elems m
    T_Data m -> "(byte,byte" <> array (maxTypeSize m) <> ")"
    T_Struct ts -> typeSig $ T_Tuple $ map snd ts
  where
    array sz = "[" <> show sz <> "]"

typeSizeOf :: DLType -> Integer
typeSizeOf = \case
  T_Null -> 0
  T_Bool -> 1
  T_UInt -> word
  T_Bytes sz -> sz
  T_Digest -> 32
  T_Address -> 32
  T_Contract -> typeSizeOf $ T_UInt
  T_Token -> typeSizeOf $ T_UInt
  T_Array t sz -> sz * typeSizeOf t
  T_Tuple ts -> sum $ map typeSizeOf ts
  T_Object m -> sum $ map typeSizeOf $ M.elems m
  T_Data m -> 1 + maxTypeSize m
  T_Struct ts -> sum $ map (typeSizeOf . snd) ts
  where
    word = 8

encodeBase64 :: B.ByteString -> LT.Text
encodeBase64 bs = LT.pack $ B.unpack $ encodeBase64' bs

texty :: Show a => a -> LT.Text
texty x = LT.pack $ show x

textyt :: Show a => a -> DLType -> LT.Text
textyt x ty = texty x <> " :: " <> texty ty

textyv :: DLVar -> LT.Text
textyv v = textyt v (varType v)

type ScratchSlot = Word8

type TealOp = LT.Text

type TealArg = LT.Text

type Label = LT.Text

data IndentDir
  = INo
  | IUp
  | IDo

data TEAL
  = TCode TealOp [TealArg]
  | TInt Integer
  | TConst LT.Text
  | TBytes B.ByteString
  | TExtract Word8 Word8
  | TSubstring Word8 Word8
  | TComment IndentDir LT.Text
  | TLabel Label
  | TFor_bnz Label Integer Label
  | TLog Integer
  | TStore ScratchSlot LT.Text
  | TLoad ScratchSlot LT.Text

type TEALt = [LT.Text]

type TEALs = DL.DList TEAL

builtin :: S.Set TealOp
builtin = S.fromList ["byte", "int", "substring", "extract", "log", "store", "load"]

render :: IORef Int -> TEAL -> IO TEALt
render ilvlr = \case
  TInt x -> r ["int", texty x]
  TConst x -> r ["int", x]
  TBytes bs -> r ["byte", "base64(" <> encodeBase64 bs <> ")"]
  TExtract x y -> r ["extract", texty x, texty y]
  TSubstring x y -> r ["substring", texty x, texty y]
  TCode f args ->
    case S.member f builtin of
      True -> impossible $ show $ "cannot use " <> f <> " directly"
      False -> r $ f : args
  TComment il t -> do
    case il of
      INo -> return ()
      IUp -> modifyIORef ilvlr $ \x -> x + 1
      IDo -> modifyIORef ilvlr $ \x -> x - 1
    case t of
      "" -> return []
      _ -> r ["//", t]
  TLabel lab -> r [lab <> ":"]
  TFor_bnz top_lab maxi _ ->
    r ["bnz", top_lab, ("// for runs " <> texty maxi <> " times")]
  TLog sz ->
    r ["log", ("// up to " <> texty sz <> " bytes")]
  TStore sl lab -> r ["store", texty sl, ("// " <> lab)]
  TLoad sl lab -> r ["load", texty sl, ("// " <> lab)]
  where
    r l = do
      i <- readIORef ilvlr
      let i' = replicate i " "
      return $ i' <> l

optimize :: [TEAL] -> [TEAL]
optimize ts0 = tsN
  where
    ts1 = opt_b ts0
    ts2 = opt_bs ts1
    tsN = ts2

opt_bs :: [TEAL] -> [TEAL]
opt_bs = \case
  [] -> []
  (TBytes x) : l | B.all (== '\0') x ->
    case B.length x of
      0 -> (TBytes mempty) : opt_bs l
      32 -> opt_bs $ (TCode "global" ["ZeroAddress"]) : l
      len -> opt_bs $ (TInt $ fromIntegral len) : (TCode "bzero" []) : l
  x : l -> x : opt_bs l

opt_b :: [TEAL] -> [TEAL]
opt_b = foldr (\a b -> opt_b1 $ a : b) mempty

opt_b1 :: [TEAL] -> [TEAL]
opt_b1 = \case
  [] -> []
  [(TCode "return" [])] -> []
  -- This relies on knowing what "done" is
  (TCode "assert" []) : (TCode "b" ["done"]) : x -> (TCode "return" []) : x
  (TBytes "") : (TCode "concat" []) : l -> l
  (TBytes "") : b@(TLoad {}) : (TCode "concat" []) : l -> opt_b1 $ b : l
  (TBytes x) : (TBytes y) : (TCode "concat" []) : l ->
    opt_b1 $ (TBytes $ x <> y) : l
  (TCode "b" [x]) : b@(TLabel y) : l | x == y -> b : l
  (TCode "btoi" []) : (TCode "itob" ["// bool"]) : (TSubstring 7 8) : l -> l
  (TCode "btoi" []) : (TCode "itob" []) : l -> l
  (TCode "itob" []) : (TCode "btoi" []) : l -> l
  (TExtract x 8) : (TCode "btoi" []) : l ->
    (TInt $ fromIntegral x) : (TCode "extract_uint64" []) : l
  a@(TLoad x _) : (TLoad y _) : l
    | x == y ->
      -- This misses if there is ANOTHER load of the same thing
      a : (TCode "dup" []) : l
  a@(TStore x _) : (TLoad y _) : l
    | x == y ->
      (TCode "dup" []) : a : l
  a@(TSubstring s0w _) : b@(TInt xn) : c@(TCode "getbyte" []) : l ->
    case xn < 256 && s0xnp1 < 256 of
      True -> opt_b1 $ (TSubstring (fromIntegral s0xn) (fromIntegral s0xnp1)) : (TCode "btoi" []) : l
      False -> a : b : c : l
    where
      s0xn :: Integer
      s0xn = (fromIntegral s0w) + xn
      s0xnp1 :: Integer
      s0xnp1 = s0xn + 1
  a@(TSubstring s0w _) : b@(TSubstring s1w e1w) : l ->
    case s2n < 256 && e2n < 256 of
      True -> opt_b1 $ (TSubstring (fromIntegral s2n) (fromIntegral e2n)) : l
      False -> a : b : l
    where
      s0n = fromIntegral s0w
      s2n :: Integer
      s2n = s0n + (fromIntegral s1w)
      e2n :: Integer
      e2n = s0n + (fromIntegral e1w)
  (TInt x) : (TCode "itob" []) : l ->
    opt_b1 $ (TBytes $ itob x) : l
  (TBytes xbs) : (TCode "btoi" []) : l ->
    opt_b1 $ (TInt $ btoi xbs) : l
  (TBytes xbs) : (TCode "sha256" []) : l ->
    opt_b1 $ (TBytes $ sha256bs xbs) : l
  (TBytes xbs) : (TCode "sha512_256" []) : l ->
    opt_b1 $ (TBytes $ sha512_256bs xbs) : l
  (TBytes xbs) : (TSubstring s e) : l ->
    opt_b1 $ (TBytes $ bsSubstring xbs (fromIntegral s) (fromIntegral e)) : l
  x : l -> x : l

sha256bs :: BS.ByteString -> BS.ByteString
sha256bs = BA.convert . hashWith SHA256
sha512_256bs :: BS.ByteString -> BS.ByteString
sha512_256bs = BA.convert . hashWith SHA512t_256

bsSubstring :: BS.ByteString -> Int -> Int -> BS.ByteString
bsSubstring bs s e = BS.take e $ BS.drop s bs

itob :: Integral a => a -> BS.ByteString
itob x = LB.toStrict $ toLazyByteString $ word64BE $ fromIntegral x

btoi :: BS.ByteString -> Integer
btoi bs = BS.foldl' (\i b -> (i `shiftL` 8) .|. fromIntegral b) 0 $ bs

checkCost :: Disp -> Bool -> [TEAL] -> IO ()
checkCost disp alwaysShow ts = do
  let mkg :: IO (IORef (LPGraph String))
      mkg = newIORef mempty
  cost_gr <- mkg
  logLen_gr <- mkg
  let lTop = "TOP"
  let lBot = "BOT"
  (labr :: IORef String) <- newIORef $ lTop
  (cost_r :: IORef Integer) <- newIORef $ 0
  (logLen_r :: IORef Integer) <- newIORef $ 0
  let l2s = LT.unpack
  let rec_ r c = modifyIORef r (c +)
  let recCost = rec_ cost_r
  let recLogLen = rec_ logLen_r
  let jump_ :: String -> Integer -> IO ()
      jump_ t k = do
        lab <- readIORef labr
        let updateGraph cr cgr = do
              c <- readIORef cr
              let ff = max (c * k)
              let fg = Just . ff . fromMaybe 0
              let f = M.alter fg t
              let g = Just . f . fromMaybe mempty
              modifyIORef cgr $ M.alter g lab
        updateGraph cost_r cost_gr
        updateGraph logLen_r logLen_gr
  let switch t = do
        writeIORef labr t
        writeIORef cost_r 0
        writeIORef logLen_r 0
  let jumpK k t = recCost 1 >> jump_ (l2s t) k
  let jump = jumpK 1
  forM_ ts $ \case
    TFor_bnz _ cnt lab' -> jumpK cnt lab'
    TCode "bnz" [lab'] -> jump lab'
    TCode "bz" [lab'] -> jump lab'
    TCode "b" [lab'] -> do
      jump lab'
      switch ""
    TCode "return" [] -> do
      jump lBot
      switch ""
    TCode "callsub" [_lab'] ->
      impossible "callsub"
    TLog len -> do
      -- Note: We don't check MaxLogCalls, because it is not actually checked
      recLogLen len
      recCost 1
    TComment {} -> return ()
    TLabel lab' -> do
      let lab'' = l2s lab'
      jump_ lab'' 1
      switch lab''
    TBytes _ -> recCost 1
    TConst _ -> recCost 1
    TStore {} -> recCost 1
    TLoad {} -> recCost 1
    TInt _ -> recCost 1
    TExtract {} -> recCost 1
    TSubstring {} -> recCost 1
    TCode f _ ->
      case f of
        "sha256" -> recCost 35
        "keccak256" -> recCost 130
        "sha512_256" -> recCost 45
        "ed25519verify" -> recCost 1900
        "ecdsa_verify" -> recCost 1700
        "ecdsa_pk_decompress" -> recCost 650
        "ecdsa_pk_recover" -> recCost 2000
        "divmodw" -> recCost 20
        "sqrt" -> recCost 4
        "expw" -> recCost 10
        "b+" -> recCost 10
        "b-" -> recCost 10
        "b/" -> recCost 20
        "b*" -> recCost 20
        "b%" -> recCost 20
        "b|" -> recCost 6
        "b&" -> recCost 6
        "b^" -> recCost 6
        "b~" -> recCost 4
        _ -> recCost 1
  let whenl x e =
        case x of
          True -> [e]
          False -> []
  let showNice x = lTop <> h x
        where
          h = \case
            [] -> ""
            (l, c) : r -> " --" <> show c <> "--> " <> l <> h r
  let analyze lab cgr units algoMax = do
        cg <- readIORef cgr
        (gs, p, c) <- longestPathBetween cg lTop (l2s lBot)
        let msg = "This program could use " <> show c <> " " <> units
        let tooMuch = fromIntegral c > algoMax
        let cs = (whenl tooMuch $ msg <> ", but the limit is " <> show algoMax <> "; longest path:\n     " <> showNice p <> "\n")
        void $ disp ("." <> lab <> ".dot") $ s2t $ "// This file is in the DOT file format. Upload or copy it into a Graphviz engine, such as https://dreampuf.github.io/GraphvizOnline\n" <> gs
        return (msg, tooMuch, cs)
  (showCost, exceedsCost, csCost) <- analyze "cost" cost_gr "units of cost" algoMaxAppProgramCost
  (showLogLen, exceedsLogLen, csLogLen) <- analyze "log" logLen_gr "bytes of logs" algoMaxLogLen
  let cs = csCost <> csLogLen
  unless (null cs) $
    emitWarning Nothing $ W_ALGOConservative cs
  let exceeds = exceedsCost || exceedsLogLen
  when (alwaysShow && not exceeds) $ do
    putStrLn $ "Conservative analysis on Algorand found:"
    putStrLn $ " * " <> showCost <> "."
    putStrLn $ " * " <> showLogLen <> "."

optimizeAndRender :: Disp -> Bool -> TEALs -> IO T.Text
optimizeAndRender disp showCost ts = do
  let tscl = DL.toList ts
  let tscl' = optimize tscl
  checkCost disp showCost tscl'
  ilvlr <- newIORef $ 0
  tsl' <- mapM (render ilvlr) tscl'
  let lts = tealVersionPragma : (map LT.unwords tsl')
  let lt = LT.unlines lts
  let t = LT.toStrict lt
  return t

data Shared = Shared
  { sFailuresR :: IORef (S.Set LT.Text)
  , sCounter :: Counter
  , sStateSizeR :: IORef Integer
  , sMaps :: DLMapInfos
  , sMapDataTy :: DLType
  , sMapDataSize :: Integer
  , sMapKeysl :: [Word8]
  , sResources :: IORef ResourceGraph
  }

type Lets = M.Map DLVar (App ())

data Env = Env
  { eShared :: Shared
  , eWhich :: Int
  , eLabel :: Counter
  , eOutputR :: IORef TEALs
  , eHP :: ScratchSlot
  , eSP :: ScratchSlot
  , eVars :: M.Map DLVar ScratchSlot
  , eLets :: Lets
  , eLetSmalls :: M.Map DLVar Bool
  , eResources :: ResourceCounters
  , eNewToks :: IORef (S.Set DLArg)
  , eInitToks :: IORef (S.Set DLArg)
  }

type App = ReaderT Env IO

recordWhich :: Int -> App a -> App a
recordWhich n = local (\e -> e {eWhich = n}) . dupeResources . resetToks

type CostGraph a = M.Map a (CostRecord a)

data CostRecord a = CostRecord
  { cr_n :: Int
  , cr_max :: S.Set a
  }
  deriving (Show)

type ResourceRec = CostRecord Int

data Resource
  = R_Txn
  | R_Asset
  | R_Account
  | R_InnerTxn
  deriving (Eq, Ord)

type ResourceGraph = M.Map Resource (CostGraph Int)

type ResourceCounter = ((S.Set DLArg), Int)

type ResourceCounters = IORef (M.Map Resource ResourceCounter)

instance Show Resource where
  show = \case
    R_Txn -> "transactions"
    R_Asset -> "assets"
    R_Account -> "accounts"
    R_InnerTxn -> "inner transactions"

maxOf :: Resource -> Integer
maxOf = \case
  R_Txn -> algoMaxTxGroupSize
  R_Asset -> algoMaxAppTxnForeignAssets
  R_Account -> algoMaxAppTxnAccounts + 1 -- XXX could detect the sender as a free account
  R_InnerTxn -> algoMaxInnerTransactions

newResources :: IO ResourceCounters
newResources = do
  newIORef $
    M.fromList $
      [ (R_Txn, (mempty, 1))
      , (R_Asset, (mempty, 0))
      , (R_Account, (mempty, 0))
      , (R_InnerTxn, (mempty, 0))
      ]

newResourceGraph :: IO (IORef ResourceGraph)
newResourceGraph = do
  newIORef $
    M.fromList $
      [ (R_Txn, mempty)
      , (R_Asset, mempty)
      , (R_Account, mempty)
      , (R_InnerTxn, mempty)
      ]

dupeResources :: App a -> App a
dupeResources m = do
  c' <- (liftIO . dupeIORef) =<< asks eResources
  local (\e -> e {eResources = c'}) m

incResourceM :: Maybe DLArg -> Resource -> App ()
incResourceM ma r = do
  rsr <- asks eResources
  let f (vs, i) =
        case ma of
          Nothing -> (vs, i + 1)
          Just a ->
            case S.member a vs of
              True -> (vs, i)
              False -> (S.insert a vs, i + 1)
  liftIO $ modifyIORef rsr $ M.adjust f r

incResource :: Resource -> App ()
incResource = incResourceM Nothing

incResourceL :: DLArg -> Resource -> App ()
incResourceL = incResourceM . Just

updateResources :: (Resource -> ResourceRec -> ResourceRec) -> App ()
updateResources f = do
  Env {..} <- ask
  let Shared {..} = eShared
  let g r = Just . (f r) . fromMaybe (CostRecord 0 mempty)
  liftIO $ modifyIORef sResources $ M.mapWithKey (\r -> M.alter (g r) eWhich)

addResourceEdge :: Int -> App ()
addResourceEdge w' = do
  addResourceCheck
  updateResources (\_ t -> t {cr_max = S.insert w' (cr_max t)})

addResourceCheck :: App ()
addResourceCheck = do
  c <- (liftIO . readIORef) =<< asks eResources
  updateResources $ \r t ->
    t {cr_n = max (snd $ c M.! r) (cr_n t)}

checkResources :: Bad' -> ResourceGraph -> IO ()
checkResources bad' rg = do
  let one emit r = do
        let maxc = maxOf r
        let tcs = rg M.! r
        -- XXX Do this not dumb
        let maximum' :: [Int] -> Int
            maximum' l = maximum $ 0 : l
        let chase i = cr_n + (maximum' $ map chase $ S.toAscList cr_max)
              where
                CostRecord {..} = tcs M.! i
        forM_ (M.keys tcs) $ \which -> do
          let amt = chase which
          when (fromIntegral amt > maxc) $ do
            emit $ "Step " <> texty which <> " could have too many " <> texty r <> ": could have " <> texty amt <> " but limit is " <> texty maxc
  let warn x = emitWarning Nothing $ W_ALGOConservative [LT.unpack x]
  one bad' R_Txn
  one warn R_Asset
  one warn R_Account
  one bad' R_InnerTxn

resetToks :: App a -> App a
resetToks m = do
  ntoks <- liftIO $ newIORef mempty
  itoks <- liftIO $ newIORef mempty
  local (\e -> e {eNewToks = ntoks, eInitToks = itoks}) m

addTok :: (Env -> IORef (S.Set DLArg)) -> DLArg -> App ()
addTok ef tok = do
  r <- asks ef
  liftIO $ modifyIORef r (S.insert tok)

addNewTok :: DLArg -> App ()
addNewTok = addTok eNewToks

addInitTok :: DLArg -> App ()
addInitTok = addTok eInitToks

isTok :: (Env -> IORef (S.Set DLArg)) -> DLArg -> App Bool
isTok ef tok = do
  ts <- (liftIO . readIORef) =<< asks ef
  return $ tok `S.member` ts

isNewTok :: DLArg -> App Bool
isNewTok = isTok eNewToks

isInitTok :: DLArg -> App Bool
isInitTok = isTok eInitToks

output :: TEAL -> App ()
output t = do
  Env {..} <- ask
  liftIO $ modifyIORef eOutputR (flip DL.snoc t)

code :: LT.Text -> [LT.Text] -> App ()
code f args = output $ TCode f args

label :: LT.Text -> App ()
label = output . TLabel

comment :: LT.Text -> App ()
comment = output . TComment INo

block_ :: LT.Text -> App () -> App ()
block_ lab m = do
  output $ TComment IUp $ ""
  output $ TComment INo $ "{ " <> lab
  m
  output $ TComment INo $ lab <> " }"
  output $ TComment IDo $ ""

block :: Label -> App () -> App ()
block lab m = block_ lab $ label lab >> m

assert :: App ()
assert = op "assert"

asserteq :: App ()
asserteq = op "==" >> assert

op :: TealOp -> App ()
op = flip code []

nop :: App ()
nop = return ()

dont_concat_first :: [App ()]
dont_concat_first = nop : repeat (op "concat")

padding :: Integer -> App ()
padding = cla . bytesZeroLit

czaddr :: App ()
czaddr = padding $ typeSizeOf T_Address

checkRekeyTo :: App ()
checkRekeyTo = do
  code "txn" ["RekeyTo"]
  czaddr
  asserteq

checkLease :: App ()
checkLease = do
  code "txn" ["Lease"]
  czaddr
  asserteq

type Bad' = LT.Text -> IO ()

bad_io :: IORef (S.Set LT.Text) -> Bad'
bad_io x = modifyIORef x . S.insert

bad :: LT.Text -> App ()
bad lab = do
  Env {..} <- ask
  let Shared {..} = eShared
  liftIO $ bad_io sFailuresR lab
  mapM_ comment $ LT.lines $ "BAD " <> lab

xxx :: LT.Text -> App ()
xxx lab = bad $ "This program uses " <> lab

freshLabel :: String -> App LT.Text
freshLabel d = do
  i <- (liftIO . incCounter) =<< (eLabel <$> ask)
  return $ "l" <> LT.pack (show i) <> "_" <> LT.pack d

loopLabel :: Int -> LT.Text
loopLabel w = "loopBody" <> LT.pack (show w)

store_let :: DLVar -> Bool -> App () -> App a -> App a
store_let dv small cgen m = do
  Env {..} <- ask
  local
    (\e ->
       e
         { eLets = M.insert dv cgen eLets
         , eLetSmalls = M.insert dv small eLetSmalls
         })
    $ m

letSmall :: DLVar -> App Bool
letSmall dv = do
  Env {..} <- ask
  return $ fromMaybe False (M.lookup dv eLetSmalls)

lookup_let :: DLVar -> App ()
lookup_let dv = do
  Env {..} <- ask
  case M.lookup dv eLets of
    Just m -> m
    Nothing ->
      impossible $ show eWhich <> " lookup_let " <> show (pretty dv) <> " not in " <> (List.intercalate ", " $ map (show . pretty) $ M.keys eLets)

store_var :: DLVar -> ScratchSlot -> App a -> App a
store_var dv ss m = do
  Env {..} <- ask
  local (\e -> e {eVars = M.insert dv ss eVars}) $
    m

lookup_var :: DLVar -> App ScratchSlot
lookup_var dv = do
  Env {..} <- ask
  case M.lookup dv eVars of
    Just x -> return $ x
    Nothing -> impossible $ "lookup_var " <> show dv

salloc :: (ScratchSlot -> App a) -> App a
salloc fm = do
  Env {..} <- ask
  let eSP' = eSP - 1
  when (eSP' == eHP) $ do
    bad "Too many scratch slots"
  local (\e -> e {eSP = eSP'}) $
    fm eSP

salloc_ :: LT.Text -> (App () -> App () -> App a) -> App a
salloc_ lab fm =
  salloc $ \loc -> do
    fm (output $ TStore loc lab) (output $ TLoad loc lab)

sallocLet :: DLVar -> App () -> App a -> App a
sallocLet dv cgen km = do
  salloc_ (textyv dv) $ \cstore cload -> do
    cgen
    cstore
    store_let dv True cload km

ctobs :: DLType -> App ()
ctobs = \case
  T_UInt -> op "itob"
  T_Bool -> code "itob" ["// bool"] >> output (TSubstring 7 8)
  T_Null -> nop
  T_Bytes _ -> nop
  T_Digest -> nop
  T_Address -> nop
  T_Contract -> ctobs T_UInt
  T_Token -> ctobs T_UInt
  T_Array {} -> nop
  T_Tuple {} -> nop
  T_Object {} -> nop
  T_Data {} -> nop
  T_Struct {} -> nop

cfrombs :: DLType -> App ()
cfrombs = \case
  T_UInt -> op "btoi"
  T_Bool -> op "btoi"
  T_Null -> nop
  T_Bytes _ -> nop
  T_Digest -> nop
  T_Address -> nop
  T_Contract -> cfrombs T_UInt
  T_Token -> cfrombs T_UInt
  T_Array {} -> nop
  T_Tuple {} -> nop
  T_Object {} -> nop
  T_Data {} -> nop
  T_Struct {} -> nop

ctzero :: DLType -> App ()
ctzero = \case
  T_UInt -> cint 0
  t -> do
    padding $ typeSizeOf t
    cfrombs t

chkint :: SrcLoc -> Integer -> Integer
chkint at i = checkIntLiteralC at conName' conCons' i

cint_ :: SrcLoc -> Integer -> App ()
cint_ at i = output $ TInt $ chkint at i

cint :: Integer -> App ()
cint = cint_ sb

cl :: DLLiteral -> App ()
cl = \case
  DLL_Null -> cbs ""
  DLL_Bool b -> cint $ if b then 1 else 0
  DLL_Int at i -> cint_ at i

cbool :: Bool -> App ()
cbool = cl . DLL_Bool

ca_boolb :: DLArg -> Maybe B.ByteString
ca_boolb = \case
  DLA_Literal (DLL_Bool b) ->
    Just $ B.singleton $ toEnum $ if b then 1 else 0
  _ -> Nothing

cas_boolbs :: [DLArg] -> Maybe B.ByteString
cas_boolbs = mconcat . map ca_boolb

cv :: DLVar -> App ()
cv = lookup_let

ca :: DLArg -> App ()
ca = \case
  DLA_Var v -> cv v
  DLA_Constant c -> cl $ conCons' c
  DLA_Literal c -> cl c
  DLA_Interact {} -> impossible "consensus interact"

argSmall :: DLArg -> App Bool
argSmall = \case
  DLA_Var v -> letSmall v
  DLA_Constant {} -> return True
  DLA_Literal {} -> return True
  DLA_Interact {} -> impossible "consensus interact"

exprSmall :: DLExpr -> App Bool
exprSmall = \case
  DLE_Arg _ a -> argSmall a
  _ -> return False

czpad :: Integer -> App ()
czpad xtra = do
  padding xtra
  op "concat"

cprim :: PrimOp -> [DLArg] -> App ()
cprim = \case
  SELF_ADDRESS {} -> impossible "self address"
  ADD -> call "+"
  SUB -> call "-"
  MUL -> call "*"
  DIV -> call "/"
  MUL_DIV -> \case
    [x, y, z] -> do
      ca x
      ca y
      op "mulw"
      cint 0
      ca z
      op "divmodw"
      op "pop"
      op "pop"
      op "swap"
      cint 0
      asserteq
    _ -> impossible "cprim: MUL_DIV args"
  MOD -> call "%"
  PLT -> call "<"
  PLE -> call "<="
  PEQ -> call "=="
  PGT -> call ">"
  PGE -> call ">="
  LSH -> call "<<"
  RSH -> call ">>"
  BAND -> call "&"
  BIOR -> call "|"
  BXOR -> call "^"
  DIGEST_EQ -> call "=="
  ADDRESS_EQ -> call "=="
  TOKEN_EQ -> call "=="
  BYTES_ZPAD xtra -> \case
    [x] -> do
      ca x
      czpad xtra
    _ -> impossible $ "zpad"
  IF_THEN_ELSE -> \case
    [be, DLA_Literal (DLL_Bool True), DLA_Literal (DLL_Bool False)] -> do
      ca be
    [be, DLA_Literal (DLL_Bool False), DLA_Literal (DLL_Bool True)] -> do
      ca be
      op "!"
    [be, DLA_Literal (DLL_Bool True), fe] -> do
      ca be
      ca fe
      op "||"
    [be, DLA_Literal (DLL_Bool False), fe] -> do
      -- be \ fe |  T  | F
      --    T    |  F  | F
      --    F    |  T  | F
      ca be
      op "!"
      ca fe
      op "&&"
    [be, te, DLA_Literal (DLL_Bool False)] -> do
      ca be
      ca te
      op "&&"
    [be, te, DLA_Literal (DLL_Bool True)] -> do
      -- be \ te |  T  | F
      --    T    |  T  | F
      --    F    |  T  | T
      ca be
      op "!"
      ca te
      op "||"
    [be, te, fe] -> do
      ca fe
      ca te
      ca be
      op "select"
    _ -> impossible "ite args"
  where
    call o = \args -> do
      forM_ args ca
      op o

cconcatbs_ :: (DLType -> App ()) -> [(DLType, App ())] -> App ()
cconcatbs_ f l = do
  let totlen = typeSizeOf $ T_Tuple $ map fst l
  check_concat_len totlen
  case l of
    [] -> padding 0
    _ -> do
      forM_ (zip l dont_concat_first) $ \((t, m), a) ->
        m >> f t >> a

cconcatbs :: [(DLType, App ())] -> App ()
cconcatbs = cconcatbs_ ctobs

check_concat_len :: Integer -> App ()
check_concat_len totlen =
  case totlen <= 4096 of
    True -> nop
    False ->
      bad $
        "Cannot `concat` " <> texty totlen
          <> " bytes; the resulting byte array must be <= 4096 bytes."
          <> " This is caused by a Reach data type being too large."

cdigest :: [(DLType, App ())] -> App ()
cdigest l = cconcatbs l >> op "sha256"

cextract :: Integer -> Integer -> App ()
cextract _s 0 = do
  op "pop"
  padding 0
cextract s l =
  case s < 256 && l < 256 && l /= 0 of
    True -> do
      output $ TExtract (fromIntegral s) (fromIntegral l)
    False -> do
      cint s
      cint l
      op "extract3"

csubstring :: Integer -> Integer -> App ()
csubstring s e = cextract s (e - s)

computeSplice :: Integer -> Integer -> Integer -> (App (), App ())
computeSplice start end tot = (before, after)
  where
    -- XXX If start == 0, then we could remove before and have another version
    -- of the callers of computeSplice
    before = cextract 0 start
    after = cextract end (tot - end)

csplice :: SrcLoc -> Integer -> Integer -> Integer -> App ()
csplice _at b c e = do
  -- [ Bytes  = X b Y c Z e , NewBytes = Y' ]
  let len = c - b
  case len == 1 of
    True -> do
      -- [ Bytes, NewByte ]
      cint b
      -- [ Bytes, NewByte, Offset ]
      op "swap"
      -- [ Bytes, Offset, NewByte ]
      op "setbyte"
    False -> salloc_ "spliceNew" $ \store_new load_new -> do
      let (cbefore, cafter) = computeSplice b c e
      -- [ Big, New ]
      store_new
      -- [ Big ]
      csplice3 Nothing cbefore cafter load_new
  -- [ Big' ]
  -- [ Bytes' = X b Y'c Z e]
  return ()

csplice3 :: Maybe (App ()) -> App () -> App () -> App () -> App ()
csplice3 Nothing cbefore cafter cnew = do
  -- [ Big ]
  op "dup"
  -- [ Big, Big ]
  cbefore
  -- [ Big, Before ]
  cnew
  -- [ Big, Before, New ]
  op "concat"
  -- [ Big, Mid' ]
  op "swap"
  -- [ Mid', Big ]
  cafter
  -- [ Mid', After ]
  op "concat"
-- [ Big' ]
csplice3 (Just cbig) cbefore cafter cnew = do
  cbig
  cbefore
  cnew
  op "concat"
  cbig
  cafter
  op "concat"

cArraySet :: SrcLoc -> (DLType, Integer) -> Maybe (App ()) -> Either Integer (App ()) -> App () -> App ()
cArraySet _at (t, alen) mcbig eidx cnew = do
  let tsz = typeSizeOf t
  let (cbefore, cafter) =
        case eidx of
          Left ii ->
            computeSplice start end tot
            where
              start = ii * tsz
              end = start + tsz
              tot = alen * tsz
          Right cidx -> (b, a)
            where
              b = do
                cint 0
                cint tsz
                cidx
                op "*"
                op "substring3"
              a = do
                cint tsz
                op "dup"
                cidx
                op "*"
                op "+"
                cint $ alen * tsz
                op "substring3"
  csplice3 mcbig cbefore cafter cnew

computeExtract :: [DLType] -> Integer -> (DLType, Integer, Integer)
computeExtract ts idx = (t, start, sz)
  where
    szs = map typeSizeOf ts
    starts = scanl (+) 0 szs
    idx' = fromIntegral idx
    tsz = zip3 ts starts szs
    (t, start, sz) =
      case atMay tsz idx' of
        Nothing -> impossible "bad idx"
        Just x -> x

cfor :: Integer -> (App () -> App ()) -> App ()
cfor 0 _ = return ()
cfor 1 body = body (cint 0)
cfor maxi body = do
  when (maxi < 2) $ impossible "cfor maxi=0"
  top_lab <- freshLabel "forTop"
  end_lab <- freshLabel "forEnd"
  block_ top_lab $ do
    salloc_ (top_lab <> "Idx") $ \store_idx load_idx -> do
      cint 0
      store_idx
      label top_lab
      body load_idx
      load_idx
      cint 1
      op "+"
      op "dup"
      store_idx
      cint maxi
      op "<"
      output $ TFor_bnz top_lab maxi end_lab
    label end_lab
    return ()

doArrayRef :: SrcLoc -> DLArg -> Bool -> Either DLArg (App ()) -> App ()
doArrayRef at aa frombs ie = do
  let (t, _) = argArrTypeLen aa
  ca aa
  cArrayRef at t frombs ie

cArrayRef :: SrcLoc -> DLType -> Bool -> Either DLArg (App ()) -> App ()
cArrayRef _at t frombs ie = do
  let tsz = typeSizeOf t
  let ie' =
        case ie of
          Left ia -> ca ia
          Right x -> x
  case t of
    T_Bool -> do
      ie'
      op "getbyte"
      case frombs of
        True -> nop
        False -> ctobs T_Bool
    _ -> do
      case ie of
        Left (DLA_Literal (DLL_Int _ ii)) -> do
          let start = ii * tsz
          cextract start tsz
        _ -> do
          cint tsz
          ie'
          op "*"
          cint tsz
          op "extract3"
      case frombs of
        True -> cfrombs t
        False -> nop

cla :: DLLargeArg -> App ()
cla = \case
  DLLA_Array t as ->
    case t of
      T_Bool ->
        case cas_boolbs as of
          Nothing -> normal
          Just x -> cbs x
      _ -> normal
    where
      normal = cconcatbs $ map (\a -> (t, ca a)) as
  DLLA_Tuple as ->
    cconcatbs $ map (\a -> (argTypeOf a, ca a)) as
  DLLA_Obj m -> cla $ DLLA_Struct $ M.toAscList m
  DLLA_Data tm vn va -> do
    let h ((k, v), i) = (k, (i, v))
    let tm' = M.fromList $ map h $ zip (M.toAscList tm) [0 ..]
    let (vi, vt) = fromMaybe (impossible $ "dla_data") $ M.lookup vn tm'
    cbs $ B.singleton $ BI.w2c vi
    ca va
    ctobs vt
    let vlen = 1 + typeSizeOf (argTypeOf va)
    op "concat"
    let dlen = typeSizeOf $ T_Data tm
    czpad $ fromIntegral $ dlen - vlen
    check_concat_len dlen
  DLLA_Struct kvs ->
    cconcatbs $ map (\a -> (argTypeOf a, ca a)) $ map snd kvs
  DLLA_Bytes bs -> cbs bs

cbs :: B.ByteString -> App ()
cbs = output . TBytes

cTupleRef :: SrcLoc -> DLType -> Integer -> App ()
cTupleRef _at tt idx = do
  -- [ Tuple ]
  let ts = tupleTypes tt
  let (t, start, sz) = computeExtract ts idx
  case (ts, idx) of
    ([_], 0) ->
      return ()
    _ -> do
      cextract start sz
  -- [ ValueBs ]
  cfrombs t
  -- [ Value ]
  return ()

computeSubstring :: [DLType] -> Integer -> (DLType, Integer, Integer)
computeSubstring ts idx = (t, start, end)
  where
    (t, start, sz) = computeExtract ts idx
    end = start + sz

cTupleSet :: SrcLoc -> DLType -> Integer -> App ()
cTupleSet at tt idx = do
  -- [ Tuple, Value' ]
  let tot = typeSizeOf tt
  let ts = tupleTypes tt
  let (t, start, end) = computeSubstring ts idx
  ctobs t
  -- [ Tuple, Value'Bs ]
  csplice at start end tot
  -- [ Tuple' ]
  return ()

cMapLoad :: App ()
cMapLoad = do
  Shared {..} <- eShared <$> ask
  labK <- freshLabel "mapLoadK"
  labReal <- freshLabel "mapLoadDo"
  labDef <- freshLabel "mapLoadDef"
  op "dup"
  code "txn" ["ApplicationID"]
  op "app_opted_in"
  code "bnz" [labReal]
  label labDef
  op "pop"
  padding sMapDataSize
  code "b" [labK]
  label labReal
  let getOne mi = do
        -- [ Address ]
        cbs $ keyVary mi
        -- [ Address, Key ]
        op "app_local_get"
        -- [ MapData ]
        return ()
  case sMapKeysl of
    -- Special case one key:
    [0] -> getOne 0
    _ -> do
      -- [ Address ]
      -- [ Address, MapData_0? ]
      forM_ (zip sMapKeysl $ False : repeat True) $ \(mi, doConcat) -> do
        -- [ Address, MapData_N? ]
        case doConcat of
          True -> code "dig" ["1"]
          False -> op "dup"
        -- [ Address, MapData_N?, Address ]
        getOne mi
        -- [ Address, MapData_N?, NewPiece ]
        case doConcat of
          True -> op "concat"
          False -> nop
        -- [ Address, MapData_N+1 ]
        return ()
      -- [ Address, MapData_k ]
      op "swap"
      op "pop"
      -- [ MapData ]
      return ()
  label labK

cMapStore :: SrcLoc -> App ()
cMapStore _at = do
  Shared {..} <- eShared <$> ask
  -- [ Address, MapData' ]
  case sMapKeysl of
    -- Special case one key:
    [0] -> do
      -- [ Address, MapData' ]
      cbs $ keyVary 0
      -- [ Address, MapData', Key ]
      op "swap"
      -- [ Address, Key, Value ]
      op "app_local_put"
    _ -> do
      forM_ sMapKeysl $ \mi -> do
        -- [ Address, MapData' ]
        code "dig" ["1"]
        -- [ Address, MapData', Address ]
        cbs $ keyVary mi
        -- [ Address, MapData', Address, Key ]
        code "dig" ["2"]
        -- [ Address, MapData', Address, Key, MapData' ]
        cStateSlice sMapDataSize mi
        -- [ Address, MapData', Address, Key, Value ]
        op "app_local_put"
        -- [ Address, MapData' ]
        return ()
      -- [ Address, MapData' ]
      op "pop"
      op "pop"
      -- [ ]
      return ()

divup :: Integer -> Integer -> Integer
divup x y = ceiling $ (fromIntegral x :: Double) / (fromIntegral y)

computeStateSizeAndKeys :: Monad m => (LT.Text -> m ()) -> LT.Text -> Integer -> Integer -> m (Integer, [Word8])
computeStateSizeAndKeys badx prefix size limit = do
  let keys = size `divup` algoMaxAppBytesValueLen_usable
  when (keys > limit) $ do
    badx $ "Too many " <> prefix <> " keys, " <> texty keys <> ", but limit is " <> texty limit
  let keysl = take (fromIntegral keys) [0 ..]
  return (keys, keysl)

cSvsLoad :: Integer -> App ()
cSvsLoad size = do
  (_, keysl) <- computeStateSizeAndKeys bad "svs" size algoMaxGlobalSchemaEntries_usable
  case null keysl of
    True -> do
      padding 0
    False -> do
      -- [ SvsData_0? ]
      forM_ (zip keysl $ False : repeat True) $ \(mi, doConcat) -> do
        -- [ SvsData_N? ]
        cbs $ keyVary mi
        -- [ SvsData_N?, Key ]
        op "app_global_get"
        -- [ SvsData_N?, NewPiece ]
        case doConcat of
          True -> op "concat"
          False -> nop
        -- [ SvsData_N+1 ]
        return ()
      -- [ SvsData_k ]
      return ()

cSvsSave :: SrcLoc -> [DLArg] -> App ()
cSvsSave _at svs = do
  let la = DLLA_Tuple svs
  let lat = largeArgTypeOf la
  let size = typeSizeOf lat
  cla la
  ctobs lat
  (_, keysl) <- computeStateSizeAndKeys bad "svs" size algoMaxGlobalSchemaEntries_usable
  ssr <- asks $ sStateSizeR . eShared
  liftIO $ modifyIORef ssr $ max size
  -- [ SvsData ]
  forM_ keysl $ \vi -> do
    -- [ SvsData ]
    cbs $ keyVary vi
    -- [ SvsData, Key ]
    code "dig" ["1"]
    -- [ SvsData, Key, SvsData ]
    cStateSlice size vi
    -- [ SvsData, Key, ViewData' ]
    op "app_global_put"
    -- [ SvsData ]
    return ()
  -- [ SvsData ]
  op "pop"
  -- [ ]
  return ()

ce :: DLExpr -> App ()
ce = \case
  DLE_Arg _ a -> ca a
  DLE_LArg _ a -> cla a
  DLE_Impossible at _ err -> expect_thrown at err
  DLE_VerifyMuldiv at _ _ _ err ->
    expect_thrown at err
  DLE_PrimOp _ p args -> cprim p args
  DLE_ArrayRef at aa ia -> doArrayRef at aa True (Left ia)
  DLE_ArraySet at aa ia va -> do
    let (t, alen) = argArrTypeLen aa
    case t of
      T_Bool -> do
        ca aa
        ca ia
        ca va
        op "setbyte"
      _ -> do
        let cnew = ca va >> ctobs t
        mcbig <-
          argSmall aa >>= \case
            False -> do
              ca aa
              return $ Nothing
            True -> do
              return $ Just $ ca aa
        let eidx =
              case ia of
                DLA_Literal (DLL_Int _ ii) -> Left ii
                _ -> Right $ ca ia
        cArraySet at (t, alen) mcbig eidx cnew
  DLE_ArrayConcat _ x y -> do
    let (xt, xlen) = argArrTypeLen x
    let (_, ylen) = argArrTypeLen y
    ca x
    ca y
    check_concat_len $ (xlen + ylen) * typeSizeOf xt
    op "concat"
  DLE_ArrayZip at x y -> do
    let xsz = typeSizeOf $ argTypeOf x
    let ysz = typeSizeOf $ argTypeOf y
    let (_, xlen) = argArrTypeLen x
    check_concat_len $ xsz + ysz
    salloc_ "arrayZip" $ \store_ans load_ans -> do
      cbs ""
      store_ans
      cfor xlen $ \load_idx -> do
        load_ans
        doArrayRef at x False $ Right load_idx
        doArrayRef at y False $ Right load_idx
        op "concat"
        op "concat"
        store_ans
      load_ans
  DLE_TupleRef at ta idx -> do
    ca ta
    cTupleRef at (argTypeOf ta) idx
  DLE_ObjectRef _at oa f -> do
    let fts = argObjstrTypes oa
    let fidx = fromIntegral $ fromMaybe (impossible "field") $ List.findIndex ((== f) . fst) fts
    let (t, start, sz) = computeExtract (map snd fts) fidx
    ca oa
    cextract start sz
    cfrombs t
  DLE_Interact {} -> impossible "consensus interact"
  DLE_Digest _ args -> cdigest $ map go args
    where
      go a = (argTypeOf a, ca a)
  DLE_Transfer mt_at who mt_amt mt_mtok -> do
    let mt_always = False
    let mt_mrecv = Just who
    let mt_mcclose = Nothing
    makeTxn $ MakeTxn {..}
  DLE_TokenInit mt_at tok -> do
    block_ "TokenInit" $ do
      let mt_always = True
      let mt_mtok = Just tok
      let mt_amt = DLA_Literal $ DLL_Int sb 0
      let mt_mrecv = Nothing
      let mt_mcclose = Nothing
      let ct_at = mt_at
      let ct_mtok = Nothing
      let ct_amt = DLA_Literal $ minimumBalance_l
      addInitTok tok
      checkTxn $ CheckTxn {..}
      makeTxn $ MakeTxn {..}
  DLE_CheckPay ct_at fs ct_amt ct_mtok -> do
    checkTxn $ CheckTxn {..}
    show_stack "CheckPay" Nothing ct_at fs
  DLE_Claim at fs t a mmsg -> do
    let check = ca a >> assert
    case t of
      CT_Assert -> impossible "assert"
      CT_Assume _ -> check
      CT_Require -> check
      CT_Possible -> impossible "possible"
      CT_Unknowable {} -> impossible "unknowable"
    show_stack "Claim" mmsg at fs
  DLE_Wait {} -> nop
  DLE_PartSet _ _ a -> ca a
  DLE_MapRef _ (DLMVar i) fa -> do
    incResourceL fa R_Account
    ca fa
    cMapLoad
    mdt <- getMapDataTy
    cTupleRef sb mdt $ fromIntegral i
  DLE_MapSet at mpv@(DLMVar i) fa mva -> do
    incResourceL fa R_Account
    Shared {..} <- eShared <$> ask
    mdt <- getMapDataTy
    mt <- getMapTy mpv
    case (length sMapKeysl) == 1 && (M.size sMaps) == 1 of
      -- Special case one key and one map
      True -> do
        ca fa
        cla $ mdaToMaybeLA mt mva
        cMapStore at
      _ -> do
        ca fa
        op "dup"
        cMapLoad
        cla $ mdaToMaybeLA mt mva
        cTupleSet at mdt $ fromIntegral i
        cMapStore at
  DLE_Remote {} -> xxx "remote objects"
  DLE_TokenNew at (DLTokenNew {..}) -> do
    block_ "TokenNew" $ do
      let ct_at = at
      let ct_mtok = Nothing
      let ct_amt = DLA_Literal $ minimumBalance_l
      checkTxn $ CheckTxn {..}
      op "itxn_begin"
      let vTypeEnum = "acfg"
      output $ TConst vTypeEnum
      makeTxn1 "TypeEnum"
      ca dtn_supply >> makeTxn1 "ConfigAssetTotal"
      maybe (cint_ at 6) ca dtn_decimals >> makeTxn1 "ConfigAssetDecimals"
      ca dtn_sym >> makeTxn1 "ConfigAssetUnitName"
      ca dtn_name >> makeTxn1 "ConfigAssetName"
      ca dtn_url >> makeTxn1 "ConfigAssetURL"
      ca dtn_metadata >> makeTxn1 "ConfigAssetMetadataHash"
      cContractAddr >> makeTxn1 "ConfigAssetManager"
      incResource R_InnerTxn
      op "itxn_submit"
      code "itxn" ["CreatedAssetID"]
  DLE_TokenBurn {} ->
    -- Burning does nothing on Algorand, because we already own it and we're
    -- the creator, and that's the rule for being able to destroy
    return ()
  DLE_TokenDestroy _at aida -> do
    op "itxn_begin"
    let vTypeEnum = "acfg"
    output $ TConst vTypeEnum
    makeTxn1 "TypeEnum"
    incResourceL aida R_Asset
    ca aida
    makeTxn1 "ConfigAsset"
    op "itxn_submit"
    incResource R_InnerTxn
  -- XXX We could give the minimum balance back to the creator
  DLE_TimeOrder {} -> impossible "timeorder"
  DLE_GetContract _ -> code "txn" ["ApplicationID"]
  DLE_GetAddress _ -> cContractAddr
  DLE_EmitLog at k vs -> do
    let internal = do
          (v, n) <- case vs of
            [v'@(DLVar _ _ _ n')] -> return (v', n')
            _ -> impossible "algo ce: Expected one value"
          clog $
            [ DLA_Literal (DLL_Int at $ fromIntegral n)
            , DLA_Var v
            ]
          cv v
          return $ v
    case k of
      L_Internal -> void $ internal
      L_Api {} -> do
        v <- internal
        op "dup"
        ctobs $ varType v
        gvStore GV_apiRet
      L_Event ml en -> do
        let name = maybe en (\l -> bunpack l <> "_" <> en) ml
        clogEvent name vs
        cl DLL_Null
  DLE_setApiDetails {} -> return ()
  DLE_GetUntrackedFunds _ mtok tb -> do
    after_lab <- freshLabel "getActualBalance"
    maybe cContractAddr ca mtok
    op "balance"
    op "dup"
    code "bz" [after_lab]
    maybe cContractAddr ca mtok
    op "min_balance"
    op "-"
    ca tb
    op "-"
    label after_lab
  DLE_FromSome _ mo da -> do
    ca da
    ca mo
    salloc_ "fromSome object" $ \cstore cload -> do
      cstore
      cextractDataOf cload da
      cload
      cint 0
      op "getbyte"
    -- [ Default, Object, Tag ]
    -- [ False, True, Cond ]
    op "select"
  where
    show_stack :: String -> Maybe BS.ByteString -> SrcLoc -> [SLCtxtFrame] -> App ()
    show_stack what msg at fs = do
      let msg' =
            case msg of
              Nothing -> ""
              Just x -> ": " <> x
      comment $ LT.pack $ "^ " <> what <> (bunpack msg')
      comment $ LT.pack $ "at " <> (unsafeRedactAbsStr $ show at)
      forM_ fs $ \f ->
        comment $ LT.pack $ unsafeRedactAbsStr $ show f

signatureStr :: String -> [DLType] -> Maybe DLType -> String
signatureStr f args mret = sig
  where
    rets = fromMaybe "" $ fmap typeSig mret
    sig = f <> "(" <> intercalate "," (map typeSig args) <> ")" <> rets

sigStrToBytes :: String -> BS.ByteString
sigStrToBytes sig = shabs
  where
    sha = hashWith SHA512t_256 $ bpack sig
    shabs = BS.take 4 $ BA.convert sha

sigStrToInt :: String -> Int
sigStrToInt = fromIntegral . btoi . sigStrToBytes

clogEvent :: String -> [DLVar] -> App ()
clogEvent eventName vs = do
  let sigStr = signatureStr eventName (map varType vs) Nothing
  let as = map DLA_Var vs
  let cheader = cbs (bpack sigStr) >> op "sha512_256" >> output (TSubstring 0 4)
  cconcatbs $ (T_Bytes 4, cheader) : map (\a -> (argTypeOf a, ca a)) as
  clog_ $ 4 + (typeSizeOf $ largeArgTypeOf $ DLLA_Tuple as)

clog_ :: Integer -> App ()
clog_ = output . TLog

clog :: [DLArg] -> App ()
clog as = do
  let la = DLLA_Tuple as
  cla la
  clog_ $ typeSizeOf $ largeArgTypeOf la

staticZero :: DLArg -> Bool
staticZero = \case
  DLA_Literal (DLL_Int _ 0) -> True
  _ -> False

data CheckTxn = CheckTxn
  { ct_at :: SrcLoc
  , ct_amt :: DLArg
  , ct_mtok :: Maybe DLArg
  }

data MakeTxn = MakeTxn
  { mt_at :: SrcLoc
  , mt_mrecv :: Maybe DLArg
  , mt_mcclose :: Maybe (App ())
  , mt_amt :: DLArg
  , mt_always :: Bool
  , mt_mtok :: Maybe DLArg
  }

checkTxn1 :: LT.Text -> App ()
checkTxn1 f = do
  code "dig" ["1"]
  code "gtxns" [f]
  asserteq

makeTxn1 :: LT.Text -> App ()
makeTxn1 f = code "itxn_field" [f]

checkTxnInit :: LT.Text -> App ()
checkTxnInit vTypeEnum = do
  -- [ txn ]
  output $ TConst vTypeEnum
  checkTxn1 "TypeEnum"
  cint 0
  checkTxn1 "Fee"
  czaddr
  checkTxn1 "Lease"
  czaddr
  checkTxn1 "RekeyTo"
  -- [ txn ]
  return ()

checkTxnUsage_ :: (DLArg -> App Bool) -> AlgoError -> SrcLoc -> Maybe DLArg -> App ()
checkTxnUsage_ isXTok err at mtok = do
  case mtok of
    Just tok -> do
      x <- isXTok tok
      when x $ do
        bad $ LT.pack $ getErrorMessage [] at True err
    Nothing -> return ()

makeTxnUsage :: SrcLoc -> Maybe DLArg -> App ()
makeTxnUsage = checkTxnUsage_ isNewTok Err_TransferNewToken

checkTxnUsage :: SrcLoc -> Maybe DLArg -> App ()
checkTxnUsage = checkTxnUsage_ isInitTok Err_PayNewToken

ntokFields :: (LT.Text, LT.Text, LT.Text, LT.Text)
ntokFields = ("pay", "Receiver", "Amount", "CloseRemainderTo")

tokFields :: (LT.Text, LT.Text, LT.Text, LT.Text)
tokFields = ("axfer", "AssetReceiver", "AssetAmount", "AssetCloseTo")

checkTxn :: CheckTxn -> App ()
checkTxn (CheckTxn {..}) = when (not (staticZero ct_amt)) $ do
  after_lab <- freshLabel "checkTxnK"
  block_ after_lab $ do
    let check1 = checkTxn1
    let ((vTypeEnum, fReceiver, fAmount, _fCloseTo), extra) =
          case ct_mtok of
            Nothing ->
              (ntokFields, return ())
            Just tok ->
              (tokFields, textra)
              where
                textra = ca tok >> check1 "XferAsset"
    checkTxnUsage ct_at ct_mtok
    ca ct_amt
    op "dup"
    code "bz" [after_lab]
    incResource R_Txn
    gvLoad GV_txnCounter
    op "dup"
    cint 1
    op "+"
    gvStore GV_txnCounter
    -- [ amt, id ]
    op "swap"
    -- [ id, amt ]
    check1 fAmount
    extra
    checkTxnInit vTypeEnum
    cContractAddr
    cfrombs T_Address
    check1 fReceiver
    label after_lab
    op "pop" -- if !always & zero then pop amt ; else pop id

makeTxn :: MakeTxn -> App ()
makeTxn (MakeTxn {..}) = when (mt_always || not (staticZero mt_amt)) $ do
  after_lab <- freshLabel "makeTxnK"
  block_ after_lab $ do
    let ((vTypeEnum, fReceiver, fAmount, fCloseTo), extra) =
          case mt_mtok of
            Nothing ->
              (ntokFields, return ())
            Just tok ->
              (tokFields, textra)
              where
                textra = do
                  incResourceL tok R_Asset
                  ca tok
                  makeTxn1 "XferAsset"
    makeTxnUsage mt_at mt_mtok
    ca mt_amt
    unless mt_always $ do
      op "dup"
      code "bz" [after_lab]
    op "itxn_begin"
    makeTxn1 fAmount
    output $ TConst vTypeEnum
    makeTxn1 "TypeEnum"
    whenJust mt_mcclose $ \cclose -> do
      cclose
      cfrombs T_Address
      makeTxn1 fCloseTo
    case mt_mrecv of
      Nothing -> cContractAddr
      Just a -> do
        incResourceL a R_Account
        ca a
    cfrombs T_Address
    makeTxn1 fReceiver
    extra
    op "itxn_submit"
    incResource R_InnerTxn
    cint 0
    label after_lab
    op "pop" -- if !always & zero then pop amt ; else pop 0

cextractDataOf :: App () -> DLArg -> App ()
cextractDataOf cd va = do
  let vt = argTypeOf va
  let sz = typeSizeOf vt
  case sz == 0 of
    True -> padding 0
    False -> do
      cd
      cextract 1 sz
      cfrombs vt

doSwitch :: String -> (a -> App ()) -> SrcLoc -> DLVar -> SwitchCases a -> App ()
doSwitch lab ck _at dv csm = do
  salloc_ (textyv dv <> " for switch") $ \cstore cload -> do
    ca $ DLA_Var dv
    cstore
    let cm1 _vi (vn, (vv, vu, k)) = do
          l <- freshLabel $ lab <> "_" <> vn
          block l $
            case vu of
              False -> ck k
              True -> do
                flip (sallocLet vv) (ck k) $ do
                  cextractDataOf cload (DLA_Var vv)
    cload
    cint 0
    op "getbyte"
    cblt lab cm1 $ bltL $ zip [0 ..] (M.toAscList csm)

cm :: App () -> DLStmt -> App ()
cm km = \case
  DL_Nop _ -> km
  DL_Let _ DLV_Eff de ->
    -- XXX this could leave something on the stack
    ce de >> km
  DL_Let _ (DLV_Let DVC_Once dv) de -> do
    sm <- exprSmall de
    store_let dv sm (ce de) km
  DL_Let _ (DLV_Let DVC_Many dv) de -> do
    sm <- exprSmall de
    recordNew <-
      case de of
        DLE_TokenNew {} -> do
          return True
        DLE_EmitLog _ _ [dv'] -> do
          isNewTok $ DLA_Var dv'
        _ -> do
          return False
    when recordNew $
      addNewTok $ DLA_Var dv
    case sm of
      True ->
        store_let dv True (ce de) km
      False ->
        sallocLet dv (ce de) km
  DL_ArrayMap at ansv aa lv (DLBlock _ _ body ra) -> do
    let anssz = typeSizeOf $ argTypeOf $ DLA_Var ansv
    let (_, xlen) = argArrTypeLen aa
    check_concat_len anssz
    salloc_ (textyv ansv) $ \store_ans load_ans -> do
      cbs ""
      store_ans
      cfor xlen $ \load_idx -> do
        load_ans
        doArrayRef at aa True $ Right load_idx
        sallocLet lv (return ()) $ do
          cp (ca ra) body
        op "concat"
        store_ans
      store_let ansv True load_ans km
  DL_ArrayReduce at ansv aa za av lv (DLBlock _ _ body ra) -> do
    let (_, xlen) = argArrTypeLen aa
    salloc_ (textyv ansv) $ \store_ans load_ans -> do
      ca za
      store_ans
      store_let av True load_ans $ do
        cfor xlen $ \load_idx -> do
          doArrayRef at aa True $ Right load_idx
          sallocLet lv (return ()) $ do
            cp (ca ra) body
          store_ans
        store_let ansv True load_ans km
  DL_Var _ dv ->
    salloc $ \loc -> do
      store_var dv loc $
        store_let dv True (output $ TLoad loc (textyv dv)) $
          km
  DL_Set _ dv da -> do
    loc <- lookup_var dv
    ca da
    output $ TStore loc (textyv dv)
    km
  DL_LocalIf _ a tp fp -> do
    ca a
    false_lab <- freshLabel "localIfF"
    join_lab <- freshLabel "localIfK"
    code "bz" [false_lab]
    cp (return ()) tp
    code "b" [join_lab]
    label false_lab
    cp (return ()) fp
    label join_lab
    km
  DL_LocalSwitch at dv csm -> do
    end_lab <- freshLabel $ "LocalSwitchK"
    doSwitch "LocalSwitch" (cp (code "b" [end_lab])) at dv csm
    label end_lab
    km
  DL_MapReduce {} ->
    impossible $ "cannot inspect maps at runtime"
  DL_Only {} ->
    impossible $ "only in CP"
  DL_LocalDo _ t -> cp km t

cp :: App () -> DLTail -> App ()
cp km = \case
  DT_Return _ -> km
  DT_Com m k -> cm (cp km k) m

ct :: CTail -> App ()
ct = \case
  CT_Com m k -> cm (ct k) m
  CT_If _ a tt ft -> do
    ca a
    false_lab <- freshLabel "ifF"
    code "bz" [false_lab]
    nct tt
    label false_lab
    nct ft
  CT_Switch at dv csm ->
    doSwitch "Switch" nct at dv csm
  CT_Jump _at which svs (DLAssignment msgm) -> do
    cla $ DLLA_Tuple $ map DLA_Var svs
    cla $ DLLA_Tuple $ map snd $ M.toAscList msgm
    addResourceEdge which
    code "b" [loopLabel which]
  CT_From at which msvs -> do
    isHalt <- do
      case msvs of
        FI_Halt toks -> do
          forM_ toks close_asset
          close_escrow
          return True
          where
            mt_at = at
            mt_always = True
            mt_mrecv = Nothing
            mt_amt = DLA_Literal $ DLL_Int sb 0
            mt_mcclose = Just $ cDeployer
            close_asset tok = makeTxn $ MakeTxn {..}
              where
                mt_mtok = Just tok
            close_escrow = makeTxn $ MakeTxn {..}
              where
                mt_mtok = Nothing
        FI_Continue svs -> do
          cSvsSave at $ map snd svs
          cint $ fromIntegral which
          gvStore GV_currentStep
          cRound
          gvStore GV_currentTime
          return False
    code "txn" ["OnCompletion"]
    output $ TConst $ if isHalt then "DeleteApplication" else "NoOp"
    asserteq
    code "b" ["updateState"]
    addResourceCheck
  where
    nct = dupeResources . ct

-- Reach Constants
reachAlgoBackendVersion :: Int
reachAlgoBackendVersion = 9

-- State:
keyState :: B.ByteString
keyState = ""

keyVary :: Word8 -> B.ByteString
keyVary = B.singleton . BI.w2c

cContractAddr :: App ()
cContractAddr = code "global" ["CurrentApplicationAddress"]

cDeployer :: App ()
cDeployer = code "global" ["CreatorAddress"]

etexty :: Enum a => a -> LT.Text
etexty = texty . fromEnum

data ArgId
  = ArgMethod
  | ArgPublish
  | ArgTime
  | ArgMsg
  deriving (Eq, Ord, Show, Enum, Bounded)

argLoad :: ArgId -> App ()
argLoad ai = code "txna" ["ApplicationArgs", etexty ai]

boundedCount :: forall a. (Enum a, Bounded a) => a -> Integer
boundedCount _ = 1 + (fromIntegral $ fromEnum $ (maxBound :: a))

argCount :: Integer
argCount = boundedCount ArgMethod

data GlobalVar
  = GV_txnCounter
  | GV_currentStep
  | GV_currentTime
  | GV_argTime
  | GV_argMsg
  | GV_wasApi
  | GV_apiRet
  deriving (Eq, Ord, Show, Enum, Bounded)

gvSlot :: GlobalVar -> ScratchSlot
gvSlot ai = fromIntegral $ fromEnum ai

gvOutput :: (ScratchSlot -> LT.Text -> TEAL) -> GlobalVar -> App ()
gvOutput f gv = output $ f (gvSlot gv) (textyt gv (gvType gv))

gvStore :: GlobalVar -> App ()
gvStore = gvOutput TStore

gvLoad :: GlobalVar -> App ()
gvLoad = gvOutput TLoad

gvType :: GlobalVar -> DLType
gvType = \case
  GV_txnCounter -> T_UInt
  GV_currentStep -> T_UInt
  GV_currentTime -> T_UInt
  GV_argTime -> T_UInt
  GV_argMsg -> T_Null
  GV_wasApi -> T_Bool
  GV_apiRet -> T_Null

keyState_gvs :: [GlobalVar]
keyState_gvs = [GV_currentStep, GV_currentTime]

keyState_ty :: DLType
keyState_ty = T_Tuple $ map gvType keyState_gvs

defn_fixed :: Label -> Bool -> App ()
defn_fixed l b = do
  label l
  cbool b
  op "return"

defn_done :: App ()
defn_done = defn_fixed "done" True

defn_fail :: App ()
defn_fail = defn_fixed "fail" False

cRound :: App ()
cRound = code "global" ["Round"]

bindTime :: DLVar -> App a -> App a
bindTime dv = store_let dv True cRound

bindSecs :: DLVar -> App a -> App a
bindSecs dv = store_let dv True (code "global" ["LatestTimestamp"])

allocDLVar :: SrcLoc -> DLType -> App DLVar
allocDLVar at t =
  DLVar at Nothing t <$> ((liftIO . incCounter) =<< ((sCounter . eShared) <$> ask))

bindFromTuple :: SrcLoc -> [DLVar] -> App a -> App a
bindFromTuple at vs m = do
  let mkArgVar l = allocDLVar at $ T_Tuple $ map varType l
  av <- mkArgVar vs
  let go = \case
        [] -> op "pop" >> m
        (dv, i) : more -> sallocLet dv cgen $ go more
          where
            cgen = ce $ DLE_TupleRef at (DLA_Var av) i
  store_let av True (op "dup") $
    go $ zip vs [0 ..]

cloop :: Int -> CHandler -> App ()
cloop _ (C_Handler {}) = return ()
cloop which (C_Loop at svs vars body) = recordWhich which $ do
  block (loopLabel which) $ do
    -- [ svs, vars ]
    let bindVars =
          id
            . (bindFromTuple at vars)
            . (bindFromTuple at svs)
    bindVars $ ct body

-- NOTE This could be compiled to a jump table if that were possible with TEAL
cblt :: String -> (Int -> a -> App ()) -> BLT Int a -> App ()
cblt lab go t = do
  -- liftIO $ putStrLn $ show t
  rec 0 Nothing t
  where
    rec low mhi = \case
      Empty -> code "b" ["fail"]
      Branch rv l r -> do
        op "dup"
        cint $ fromIntegral rv
        op "<"
        llab <- freshLabel $ lab <> "_lt_" <> show rv
        code "bnz" [llab]
        rec rv mhi r
        label llab
        rec low (Just $ rv - 1) l
      Leaf which h -> do
        case (which == low && mhi == Just which) of
          True -> op "pop"
          False -> do
            cint $ fromIntegral which
            asserteq
        go which h

handlerLabel :: Int -> Label
handlerLabel w = "publish" <> texty w

ch :: Int -> CHandler -> App ()
ch _ (C_Loop {}) = return ()
ch which (C_Handler at int from prev svs msg timev secsv body) = recordWhich which $ do
  let isCtor = which == 0
  let argSize = 1 + (typeSizeOf $ T_Tuple $ map varType $ msg)
  when (argSize > algoMaxAppTotalArgLen) $
    xxx $ texty $ "Step " <> show which <> "'s argument length is " <> show argSize <> ", but the maximum is " <> show algoMaxAppTotalArgLen
  let bindFromMsg vs m = do
        gvLoad GV_argMsg
        op "dup"
        op "len"
        cint $ typeSizeOf $ (T_Tuple $ map varType vs)
        asserteq
        bindFromTuple at vs m
  let bindFromSvs m = do
        cSvsLoad $ typeSizeOf $ T_Tuple $ map varType svs
        bindFromTuple at svs m
  block (handlerLabel which) $ do
    comment "check step"
    cint $ fromIntegral prev
    gvLoad GV_currentStep
    asserteq
    comment "check time"
    gvLoad GV_argTime
    op "dup"
    cint 0
    op "=="
    op "swap"
    gvLoad GV_currentTime
    op "=="
    op "||"
    assert
    let bindVars =
          id
            . (store_let from True (code "txn" ["Sender"]))
            . (bindTime timev)
            . (bindSecs secsv)
            . bindFromSvs
            . (bindFromMsg msg)
    bindVars $ do
      clogEvent ("_reach_e" <> show which) msg
      when isCtor $ do
        ce $ DLE_CheckPay at [] (DLA_Literal $ minimumBalance_l) Nothing
      let checkTime1 :: LT.Text -> App () -> DLArg -> App ()
          checkTime1 cmp clhs rhsa = do
            clhs
            ca rhsa
            op cmp
            assert
      let checkFrom_ = checkTime1 ">="
      let checkTo_ = checkTime1 "<"
      let makeCheck check_ = \case
            Left x -> check_ (cv timev) x
            Right x -> check_ (cv secsv) x
      let checkFrom = makeCheck checkFrom_
      let checkTo = makeCheck checkTo_
      let checkBoth v xx yy = do
            cv v
            checkFrom_ (op "dup") xx
            checkTo_ (return ()) yy
      let CBetween ifrom ito = int
      case (ifrom, ito) of
        (Nothing, Nothing) -> return ()
        (Just x, Nothing) -> checkFrom x
        (Nothing, Just y) -> checkTo y
        (Just x, Just y) ->
          case (x, y) of
            (Left xx, Left yy) -> checkBoth timev xx yy
            (Right xx, Right yy) -> checkBoth secsv xx yy
            (_, _) -> checkFrom x >> checkFrom y
      ct body

getMapTy :: DLMVar -> App DLType
getMapTy mpv = do
  ms <- ((sMaps . eShared) <$> ask)
  return $
    case M.lookup mpv ms of
      Nothing -> impossible "getMapTy"
      Just mi -> dlmi_ty mi

mapDataTy :: DLMapInfos -> DLType
mapDataTy m = T_Tuple $ map (dlmi_tym . snd) $ M.toAscList m

getMapDataTy :: App DLType
getMapDataTy = (sMapDataTy . eShared) <$> ask

type Disp = String -> T.Text -> IO String

cStateSlice :: Integer -> Word8 -> App ()
cStateSlice size iw = do
  let i = fromIntegral iw
  let k = algoMaxAppBytesValueLen_usable
  csubstring (k * i) (min size $ k * (i + 1))

compileTEAL :: String -> IO BS.ByteString
compileTEAL tealf = do
  (ec, stdout, stderr) <- readProcessWithExitCode "goal" ["clerk", "compile", tealf, "-o", "-"] mempty
  case ec of
    ExitFailure _ ->
      impossible $ "The TEAL compiler failed with the message:\n" <> show stderr
    ExitSuccess -> return stdout

data CApi = CApi
  { capi_who :: SLPart
  , capi_sig :: String
  , capi_which :: Int
  , capi_arg_tys :: [DLType]
  , capi_doWrap :: App ()
  }

apiSig :: (SLPart, ApiInfo) -> (String, CApi)
apiSig (who, (ApiInfo {..})) = (capi_sig, c)
  where
    c = CApi {..}
    capi_who = who
    capi_which = ai_which
    capi_sig = signatureStr f capi_arg_tys mret
    f = bunpack who
    imp = impossible "apiSig"
    (capi_arg_tys, capi_doWrap) =
      case ai_compile of
        AIC_SpreadArg ->
          case ai_msg_tys of
            [T_Tuple ts] -> (ts, return ())
            _ -> imp
        AIC_Case ->
          case ai_msg_tys of
            [T_Data tm] ->
              case M.lookup cid tm of
                Just (T_Tuple ts) -> (ts, doWrapData ts $ cla . DLLA_Data tm cid)
                _ -> imp
            _ -> imp
    cid = fromMaybe imp ai_mcase_id
    ret = ai_ret_ty
    mret = Just $ ret

doWrapData :: [DLType] -> (DLArg -> App ()) -> App ()
doWrapData tys mk = do
  -- Tuple of tys is on stack
  av <- allocDLVar sb $ T_Tuple tys
  sallocLet av (return ()) $ mk (DLA_Var av)

-- Data of tys is on stack

capi :: Int -> CApi -> App ()
capi sigi (CApi who sig which tys doWrap) = do
  block_ (LT.pack $ bunpack who) $ do
    comment $ LT.pack $ "API: " <> sig
    comment $ LT.pack $ " ui: " <> show sigi
    let f :: DLType -> Integer -> (DLType, App ())
        f t i = (t, code "txna" ["ApplicationArgs", texty i])
    cconcatbs_ (const $ return ()) $ zipWith f tys [1 ..]
    doWrap
    gvStore GV_argMsg
    code "b" [handlerLabel which]

compile_algo :: CompilerToolEnv -> Disp -> PLProg -> IO ConnectorInfo
compile_algo env disp pl = do
  let PLProg _at plo dli _ _ cpp = pl
  let CPProg at _ ai _ (CHandlers hm) = cpp
  let maxApiRetSize = maxTypeSize $ M.map ai_ret_ty ai
  let ai_sm = M.fromList $ map apiSig $ M.toAscList ai
  let ai_im = M.mapKeys sigStrToInt ai_sm
  let sMaps = dli_maps dli
  resr <- newIORef mempty
  sFailuresR <- newIORef mempty
  sResources <- newResourceGraph
  let sMapDataTy = mapDataTy sMaps
  let sMapDataSize = typeSizeOf sMapDataTy
  let PLOpts {..} = plo
  let sCounter = plo_counter
  let recordSize prefix size = do
        modifyIORef resr $
          M.insert (prefix <> "Size") $
            Aeson.Number $ fromIntegral size
  let recordSizeAndKeys :: T.Text -> Integer -> Integer -> IO [Word8]
      recordSizeAndKeys prefix size limit = do
        let badx = bad_io sFailuresR
        (keys, keysl) <- computeStateSizeAndKeys badx (LT.fromStrict prefix) size limit
        recordSize prefix size
        modifyIORef resr $
          M.insert (prefix <> "Keys") $
            Aeson.Number $ fromIntegral keys
        return $ keysl
  sMapKeysl <- recordSizeAndKeys "mapData" sMapDataSize algoMaxLocalSchemaEntries_usable
  sStateSizeR <- newIORef 0
  let eShared = Shared {..}
  let run :: App () -> IO TEALs
      run m = do
        eLabel <- newCounter 0
        eOutputR <- newIORef mempty
        let eHP = fromIntegral $ fromEnum (maxBound :: GlobalVar)
        let eSP = 255
        let eVars = mempty
        let eLets = mempty
        let eLetSmalls = mempty
        let eWhich = 0
        eNewToks <- newIORef mempty
        eInitToks <- newIORef mempty
        eResources <- newResources
        flip runReaderT (Env {..}) m
        readIORef eOutputR
  let bad' = bad_io sFailuresR
  totalLenR <- newIORef (0 :: Integer)
  let addProg lab showCost m = do
        ts <- run m
        let disp' = disp . (lab <>)
        t <- optimizeAndRender disp' showCost ts
        tf <- disp (lab <> ".teal") t
        tbs <- compileTEAL tf
        modifyIORef totalLenR $ (+) (fromIntegral $ BS.length tbs)
        let tc = LT.toStrict $ encodeBase64 tbs
        modifyIORef resr $ M.insert (T.pack lab) $ Aeson.String tc
  addProg "appApproval" (cte_REACH_DEBUG env) $ do
    when False $ do
      -- We don't check these, because they don't interfere with how we work.
      checkRekeyTo
      checkLease
    cint 0
    gvStore GV_txnCounter
    code "txn" ["ApplicationID"]
    code "bz" ["alloc"]
    cbs keyState
    op "app_global_get"
    let nats = [0 ..]
    let shouldDups = reverse $ zipWith (\_ i -> i /= 0) keyState_gvs nats
    forM_ (zip (zip keyState_gvs shouldDups) nats) $ \((gv, shouldDup), i) -> do
      when shouldDup $ op "dup"
      cTupleRef at keyState_ty i
      gvStore gv
    unless (null sMapKeysl) $ do
      -- NOTE We could allow an OptIn if we are not going to halt
      code "txn" ["OnCompletion"]
      output $ TConst "OptIn"
      op "=="
      code "bz" ["normal"]
      code "txn" ["Sender"]
      padding sMapDataSize
      cMapStore at
      code "b" ["checkSize"]
      -- The NON-OptIn case:
      label "normal"
    when False $ do
      -- NOTE: We don't actually care about this, because there will be a
      -- different failure if there are too few and if there are too few, who
      -- cares?
      code "txn" ["NumAppArgs"]
      cint argCount
      asserteq
    argLoad ArgMethod
    cfrombs T_UInt
    label "preamble"
    op "dup"
    code "bz" ["publish"]
    label "api"
    cint 0
    gvStore GV_argTime
    cbool True
    gvStore GV_wasApi
    cblt "api" capi $ bltM ai_im
    label "publish"
    argLoad ArgPublish
    cfrombs T_UInt
    argLoad ArgTime
    cfrombs T_UInt
    gvStore GV_argTime
    argLoad ArgMsg
    gvStore GV_argMsg
    cblt "publish" ch $ bltM hm
    forM_ (M.toAscList hm) $ \(hi, hh) ->
      cloop hi hh
    label "updateState"
    cbs keyState
    forM_ keyState_gvs $ \gv -> do
      gvLoad gv
      ctobs $ gvType gv
    forM_ (tail keyState_gvs) $ const $ op "concat"
    op "app_global_put"
    gvLoad GV_wasApi
    code "bz" ["checkSize"]
    label "apiReturn"
    -- SHA-512/256("return")[0..4] = 0x151f7c75
    cbs $ BS.pack [0x15, 0x1f, 0x7c, 0x75]
    gvLoad GV_apiRet
    op "concat"
    clog_ $ 4 + maxApiRetSize
    code "b" ["checkSize"]
    label "checkSize"
    gvLoad GV_txnCounter
    op "dup"
    -- The size is correct
    cint 1
    op "+"
    code "global" ["GroupSize"]
    asserteq
    -- We're last
    code "txn" ["GroupIndex"]
    asserteq
    when False $ do
      -- There's no point to checking this, because if the fee is too much,
      -- there's no harm and if it is too low, the network will reject it
      -- anyways
      cint algoMinTxnFee
      op "*"
      code "txn" ["Fee"]
      op "<="
      assert
    code "b" ["done"]
    defn_done
    defn_fail
    label "alloc"
    code "txn" ["OnCompletion"]
    output $ TConst "NoOp"
    asserteq
    forM_ keyState_gvs $ \gv -> do
      ctzero $ gvType gv
      gvStore gv
    code "b" ["updateState"]
  -- Clear state is never allowed
  addProg "appClear" False $ do
    cbool False
  checkResources bad' =<< readIORef sResources
  stateSize <- readIORef sStateSizeR
  void $ recordSizeAndKeys "state" stateSize algoMaxGlobalSchemaEntries_usable
  totalLen <- readIORef totalLenR
  unless (totalLen <= algoMaxAppProgramLen_really) $ do
    bad' $ texty $ "The program is too long; its length is " <> show totalLen <> ", but the maximum possible length is " <> show algoMaxAppProgramLen_really
  let extraPages :: Integer = ceiling ((fromIntegral totalLen :: Double) / fromIntegral algoMaxAppProgramLen) - 1
  modifyIORef resr $
    M.insert "extraPages" $
      Aeson.Number $ fromIntegral $ extraPages
  sFailures <- readIORef sFailuresR
  modifyIORef resr $
    M.insert "unsupported" $
      aarray $
        S.toList $ S.map (Aeson.String . LT.toStrict) sFailures
  unless (null sFailures) $ do
    emitWarning Nothing $ W_ALGOUnsupported $ S.toList $ S.map LT.unpack sFailures
  let apiSigs = M.keys ai_sm
  modifyIORef resr $
    M.insert "ABI" $
      aobject $
        M.fromList $
          [ ("sigs", aarray $ map (Aeson.String . s2t) apiSigs)
          ]
  modifyIORef resr $
    M.insert "version" $
      Aeson.Number $ fromIntegral $ reachAlgoBackendVersion
  res <- readIORef resr
  return $ aobject res

connect_algo :: CompilerToolEnv -> Connector
connect_algo env = Connector {..}
  where
    conName = conName'
    conCons = conCons'
    conGen moutn pl = case moutn of
      Nothing -> withSystemTempDirectory "reachc-algo" $ \d ->
        go (\w -> d </> T.unpack w) pl
      Just outn -> go outn pl
    go :: (T.Text -> String) -> PLProg -> IO ConnectorInfo
    go outn = compile_algo env disp
      where
        disp :: String -> T.Text -> IO String
        disp which c = do
          let oi = which
          let oit = T.pack oi
          let f = outn oit
          conWrite (Just outn) oit c
          return f
