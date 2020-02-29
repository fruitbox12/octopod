{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE TypeOperators     #-}

module DMS.Lib
    ( runDMS
    ) where

import Prelude hiding (lines, unlines, unwords)

import Control.Exception (throwIO, Exception)
import Control.Monad.IO.Class
import Control.Monad.Trans.Reader  (ReaderT, ask, runReaderT)
import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.Monoid ((<>))
import Data.Text (lines, pack, unlines, unpack, unwords)
import Data.Pool
import Database.PostgreSQL.Simple
import Options.Generic
import Network.Wai.Handler.Warp
import Servant
import System.Exit
import System.Log.FastLogger
import System.Process.Typed

import API.Lib (Deployment (Deployment), DeploymentAPI, name, tag, envs)
import DMS.Helm

data Args
  = Args { port :: Int, db :: ByteString, dbPoolSize :: Int }
  deriving (Generic, Show)

instance ParseRecord Args where
  parseRecord = parseRecordWithModifiers lispCaseModifiers

type PgPool = Pool Connection
type AppM = ReaderT State Handler

data State
  = State { pool :: PgPool, logger :: TimedFastLogger, helm :: FilePath, b2bHelm :: FilePath }

newtype DeploymentException = DeploymentFailed Int
  deriving (Show)

instance Exception DeploymentException

runDMS :: IO ()
runDMS = do
  timeCache <- newTimeCache "%Y-%m-%d %T%z"
  (logger, cleanUp) <- newTimedFastLogger timeCache (LogStdout defaultBufSize)
  logInfo logger "started"
  args <- getRecord "DMS"
  helm <- helmPath
  b2bHelm <- b2bHelmPath
  case (helm, b2bHelm) of
    (Just h, Just b) -> do
      pool <- initConnectionPool (db args) (dbPoolSize args)
      run (port args) (app $ State pool logger h b)
    (Nothing, _) -> die "helm not found"
    (_, _) -> die "b2b-helm not found"

initConnectionPool :: ByteString -> Int -> IO PgPool
initConnectionPool db = createPool (connectPostgreSQL db) close 1 30

nt :: State -> AppM a -> Handler a
nt s x = runReaderT x s

app :: State -> Application
app s = serve deploymentAPI $ hoistServer deploymentAPI (nt s) server

deploymentAPI :: Proxy DeploymentAPI
deploymentAPI = Proxy

server :: ServerT DeploymentAPI AppM
server = (list :<|> create :<|> get :<|> edit :<|> destroy :<|> update) :<|> ping

list :: AppM [Text]
list = do
  State{pool = p, logger = l} <- ask
  ds <- getDeployments p
  liftIO . logInfo l $ "get deployments: " <> (pack . show $ ds)
  return ds

  where
    getDeployments :: PgPool -> AppM [Text]
    getDeployments p = fmap (fmap fromOnly) . liftIO $
      withResource p $ \conn -> query_ conn "SELECT name FROM deployments"

create :: Deployment -> AppM Text
create d = do
  State{pool = p, logger = l, b2bHelm = b} <- ask
  let ia = infraArgs d
      aa = appArgs d
  liftIO $ do
    createDeployment p d
    logInfo l $ "call " <> unwords (pack <$> b : ia)
    ec1 <- createInfra ia b
    logInfo l $ "call " <> unwords (pack <$> b : aa)
    ec2 <- createApp aa b
    logInfo l $ "deployment created, deployment: " <> (pack . show $ d)
    let ec = max ec1 ec2
    createDeploymentLog p d "create" ec
    handleExitCode ec
  return ""

  where
    createDeployment :: PgPool -> Deployment -> IO Int64
    createDeployment p Deployment { name = n, tag = t, envs = e } = withResource p $ \conn ->
      execute conn "INSERT INTO deployments (name, tag, envs) VALUES (?, ?, ?)" (n, t, unlines e)

    infraArgs Deployment { name = n } = createInfraArgs . unpack $ n

    appArgs Deployment { name = n, tag = t, envs = e } = createAppArgs (unpack n) (unpack t) (fmap unpack e)

    createInfra :: [String] -> String -> IO ExitCode
    createInfra args b2bHelm = withProcessWait (proc b2bHelm args) waitProcess

    createApp :: [String] -> String -> IO ExitCode
    createApp args b2bHelm = withProcessWait (proc b2bHelm args) waitProcess

get :: Text -> AppM [Deployment]
get n = do
  State{pool = p, logger = l} <- ask
  liftIO $ do
    d <- getDeployment p
    logInfo l $ "get deployment: " <> (pack . show $ d)
    return d

  where
    getDeployment :: PgPool -> IO [Deployment]
    getDeployment p = fmap (fmap (\(n, t, e) -> Deployment n t $ lines e)) $ withResource p $ \conn ->
      query conn "SELECT name, tag, envs FROM deployments WHERE name = ?" (Only n)

edit :: Text -> Deployment -> AppM Text
edit n d@Deployment { envs =  e } = do
  State{pool = p, logger = l, b2bHelm = b} <- ask
  t <- liftIO $ getTag p
  case t of
    t : _ -> do
      let d' = d { name = n, tag = t }
          aa = appArgs d'
      liftIO $ do
        editDeployment p
        logInfo l $ "call " <> unwords (pack <$> b : aa)
        ec <- editApp aa b
        logInfo l $ "deployment edited, name: " <> n <> ", envs: " <> unwords e
        createDeploymentLog p d' "edit" ec
        handleExitCode ec
        return ()
    _ -> liftIO . logWarning l $ "tag not found, name: " <> n
  return ""

  where
    getTag :: PgPool -> IO [Text]
    getTag p = fmap (fmap fromOnly) $ withResource p $ \conn ->
      query conn "SELECT tag FROM deployments WHERE name = ?" (Only n)

    editDeployment :: PgPool -> IO Int64
    editDeployment p = withResource p $ \conn ->
      execute conn "UPDATE deployments SET envs = ?, updated_at = now() WHERE name = ?" (unlines e, n)

    editApp :: [String] -> String -> IO ExitCode
    editApp args b2bHelm = liftIO . withProcessWait (proc b2bHelm args) $ waitProcess

    appArgs Deployment { name = n, tag = t, envs =  e } = editAppArgs (unpack n) (unpack t) (fmap unpack e)

destroy :: Text -> AppM Text
destroy n = do
  State{pool = p, logger = l, helm = h} <- ask
  let ia = infraArgs n
      aa = appArgs n
  liftIO $ do
    logInfo l $ "call " <> unwords (pack <$> h : aa)
    ec1 <- destroyApp aa h
    logInfo l $ "call " <> unwords (pack <$> h : ia)
    ec2 <- destroyInfra ia h
    deleteDeploymentLogs p
    deleteDeployment p
    logInfo l $ "deployment destroyed, name: " <> n
    handleExitCode $ max ec1 ec2
  return ""

  where
    deleteDeploymentLogs :: PgPool -> IO Int64
    deleteDeploymentLogs p = withResource p $ \conn ->
      execute conn "DELETE FROM deployment_logs WHERE deployment_id in (SELECT id FROM deployments where name = ?)" (Only n)

    deleteDeployment :: PgPool -> IO Int64
    deleteDeployment p = withResource p $ \conn ->
      execute conn "DELETE FROM deployments WHERE name = ?" (Only n)

    infraArgs = destroyInfraArgs . unpack

    appArgs = destroyAppArgs . unpack

    destroyApp :: [String] -> String -> IO ExitCode
    destroyApp args helm = withProcessWait (proc helm args) waitProcess

    destroyInfra :: [String] -> String -> IO ExitCode
    destroyInfra args helm = withProcessWait (proc helm args) waitProcess

update :: Text -> Deployment -> AppM Text
update n d@Deployment { tag = t } = do
  State{pool = p, logger = l, b2bHelm = b} <- ask
  e <- liftIO $ getEnvs p
  case e of
    e : _ -> do
      let d' = d { name = n, envs = lines e }
          aa = appArgs d'
      liftIO $ do
        updateDeployment p
        logInfo l $ "call " <> unwords (pack <$> b : aa)
        ec <- updateApp aa b
        logInfo l $ "deployment updated, name: " <> n <> ", tag: " <> t
        createDeploymentLog p d' "update" ec
        handleExitCode ec
        return ()
    _ -> liftIO . logWarning l $ "envs not found, name: " <> n
  return ""

  where
    getEnvs :: PgPool -> IO [Text]
    getEnvs p = fmap (fmap fromOnly) $ withResource p $ \conn ->
      query conn "SELECT envs FROM deployments WHERE name = ?" (Only n)

    updateDeployment :: PgPool -> IO Int64
    updateDeployment p = withResource p $ \conn ->
      execute conn "UPDATE deployments SET tag = ?, updated_at = now() WHERE name = ?" (t, n)

    updateApp :: [String] -> String -> IO ExitCode
    updateApp args b2bHelm = withProcessWait (proc b2bHelm args) waitProcess

    appArgs Deployment { name = n, tag = t, envs = e } = updateAppArgs (unpack n) (unpack t) (fmap unpack e)

ping :: AppM Text
ping = do
  State{pool = p} <- ask
  getSomething p
  return ""

  where
    getSomething :: PgPool -> AppM [Int]
    getSomething p = fmap (fmap fromOnly) . liftIO $
      withResource p $ \conn -> query_ conn "SELECT id FROM deployments WHERE id = 0"

waitProcess :: (Show stdout, Show stderr) => Process stdin stdout stderr -> IO ExitCode
waitProcess p = do
  print . getStdout $ p
  print . getStderr $ p
  waitExitCode p

handleExitCode :: ExitCode -> IO ()
handleExitCode ExitSuccess = return ()
handleExitCode (ExitFailure c) = throwIO $ DeploymentFailed c

createDeploymentLog :: PgPool -> Deployment -> Text -> ExitCode -> IO Int64
createDeploymentLog pool Deployment {name = n, tag = t, envs = e} action exitCode
  = withResource pool $ \conn -> execute conn q (action, t, unlines e, exitCode', n)

  where q = "INSERT INTO deployment_logs (deployment_id, action, tag, envs, exit_code) (\
              \SELECT id, ?, ?, ?, ? \
              \FROM deployments \
              \WHERE name = ? \
            \)"
        exitCode' = case exitCode of
                      ExitSuccess -> 0
                      ExitFailure e -> e

logInfo :: TimedFastLogger -> Text -> IO ()
logInfo logger = logWithSeverity logger "INFO"

logWarning :: TimedFastLogger -> Text -> IO ()
logWarning logger = logWithSeverity logger "WARN"

logWithSeverity :: ToLogStr msg => TimedFastLogger -> ByteString -> msg -> IO ()
logWithSeverity logger severity msg = logger $ \ft -> metadata ft <> message
  where metadata ft = foldMap toLogStr ["[" :: ByteString, ft, " " :: ByteString, severity, "] " :: ByteString]
        message = toLogStr msg <> toLogStr ("\n" :: ByteString)
