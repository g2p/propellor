module Propellor.Types.PrivData where

import Propellor.Types.OS

-- | Note that removing or changing field names will break the
-- serialized privdata files, so don't do that!
-- It's fine to add new fields.
data PrivDataField
	= DockerAuthentication
	| SshPubKey SshKeyType UserName
	| SshPrivKey SshKeyType UserName
	| SshAuthorizedKeys UserName
	| Password UserName
	| CryptPassword UserName
	| PrivFile FilePath
	| GpgKey
	deriving (Read, Show, Ord, Eq)

-- | Combines a PrivDataField with a description of how to generate
-- its value.
data PrivDataSource
	= PrivDataSourceFile PrivDataField FilePath
	| PrivDataSourceFileFromCommand PrivDataField FilePath String
	| PrivDataSource PrivDataField String

class IsPrivDataSource s where
	privDataField :: s -> PrivDataField
	describePrivDataSource :: s -> Maybe String

instance IsPrivDataSource PrivDataField where
	privDataField = id
	describePrivDataSource _ = Nothing

instance IsPrivDataSource PrivDataSource where
	privDataField s = case s of
		PrivDataSourceFile f _ -> f
		PrivDataSourceFileFromCommand f _ _ -> f
		PrivDataSource f _ -> f
	describePrivDataSource s = Just $ case s of
		PrivDataSourceFile _ f -> "< " ++ f
		PrivDataSourceFileFromCommand _ f c ->
			"< " ++ f ++ " (created by running, for example, `" ++ c ++ "` )"
		PrivDataSource _ d -> "< (" ++ d ++ ")"

-- | A context in which a PrivDataField is used.
--
-- Often this will be a domain name. For example, 
-- Context "www.example.com" could be used for the SSL cert
-- for the web server serving that domain. Multiple hosts might
-- use that privdata.
--
-- This appears in serlialized privdata files.
newtype Context = Context String
	deriving (Read, Show, Ord, Eq)

-- | A context that varies depending on the HostName where it's used.
newtype HostContext = HostContext { mkHostContext :: HostName -> Context }

instance Show HostContext where
	show hc = show $ mkHostContext hc "<hostname>"

instance Ord HostContext where
	a <= b = show a <= show b

instance Eq HostContext where
	a == b = show a == show b

-- | Class of things that can be used as a Context.
class IsContext c where
	asContext :: HostName -> c -> Context
	asHostContext :: c -> HostContext

instance IsContext HostContext where
	asContext = flip mkHostContext
	asHostContext = id

instance IsContext Context where
	asContext _ c = c
	asHostContext = HostContext . const

-- | Use when a PrivDataField is not dependent on any paricular context.
anyContext :: Context
anyContext = Context "any"

-- | Makes a HostContext that consists just of the hostname.
hostContext :: HostContext
hostContext = HostContext Context

type PrivData = String

data SshKeyType = SshRsa | SshDsa | SshEcdsa | SshEd25519
	deriving (Read, Show, Ord, Eq)

-- | Parameter that would be passed to ssh-keygen to generate key of this type
sshKeyTypeParam :: SshKeyType -> String
sshKeyTypeParam SshRsa = "RSA"
sshKeyTypeParam SshDsa = "DSA"
sshKeyTypeParam SshEcdsa = "ECDSA"
sshKeyTypeParam SshEd25519 = "ED25519"

