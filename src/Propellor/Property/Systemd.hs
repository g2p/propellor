module Propellor.Property.Systemd (
	module Propellor.Property.Systemd.Core,
	started,
	stopped,
	enabled,
	disabled,
	persistentJournal,
	daemonReloaded,
	Container,
	container,
	nspawned,
	containerCfg,
	resolvConfed,
) where

import Propellor
import Propellor.Types.Chroot
import qualified Propellor.Property.Chroot as Chroot
import qualified Propellor.Property.Apt as Apt
import qualified Propellor.Property.File as File
import Propellor.Property.Systemd.Core
import Utility.SafeCommand
import Utility.FileMode

import Data.List
import Data.List.Utils
import qualified Data.Map as M

type ServiceName = String

type MachineName = String

data Container = Container MachineName Chroot.Chroot Host
	deriving (Show)

instance Hostlike Container where
        (Container n c h) & p = Container n c (h & p)
        (Container n c h) &^ p = Container n c (h &^ p)
        getHost (Container _ _ h) = h

-- | Starts a systemd service.
started :: ServiceName -> Property
started n = trivial $ cmdProperty "systemctl" ["start", n]
	`describe` ("service " ++ n ++ " started")

-- | Stops a systemd service.
stopped :: ServiceName -> Property
stopped n = trivial $ cmdProperty "systemctl" ["stop", n]
	`describe` ("service " ++ n ++ " stopped")

-- | Enables a systemd service.
enabled :: ServiceName -> Property
enabled n = trivial $ cmdProperty "systemctl" ["enable", n]
	`describe` ("service " ++ n ++ " enabled")

-- | Disables a systemd service.
disabled :: ServiceName -> Property
disabled n = trivial $ cmdProperty "systemctl" ["disable", n]
	`describe` ("service " ++ n ++ " disabled")

-- | Enables persistent storage of the journal.
persistentJournal :: Property
persistentJournal = check (not <$> doesDirectoryExist dir) $ 
	combineProperties "persistent systemd journal"
		[ cmdProperty "install" ["-d", "-g", "systemd-journal", dir]
		, cmdProperty "setfacl" ["-R", "-nm", "g:adm:rx,d:g:adm:rx", dir]
		, started "systemd-journal-flush"
		]
		`requires` Apt.installed ["acl"]
  where
	dir = "/var/log/journal"

-- | Causes systemd to reload its configuration files.
daemonReloaded :: Property
daemonReloaded = trivial $ cmdProperty "systemctl" ["daemon-reload"]

-- | Defines a container with a given machine name.
--
-- Properties can be added to configure the Container.
--
-- > container "webserver" (Chroot.debootstrapped (System (Debian Unstable) "amd64") mempty)
-- >    & Apt.installedRunning "apache2"
-- >    & ...
container :: MachineName -> (FilePath -> Chroot.Chroot) -> Container
container name mkchroot = Container name c h
	& os system
	& resolvConfed
  where
	c@(Chroot.Chroot _ system _ _) = mkchroot (containerDir name)
	h = Host name [] mempty

-- | Runs a container using systemd-nspawn.
--
-- A systemd unit is set up for the container, so it will automatically
-- be started on boot.
--
-- Systemd is automatically installed inside the container, and will
-- communicate with the host's systemd. This allows systemctl to be used to
-- examine the status of services running inside the container.
--
-- When the host system has persistentJournal enabled, journactl can be
-- used to examine logs forwarded from the container.
--
-- Reverting this property stops the container, removes the systemd unit,
-- and deletes the chroot and all its contents.
nspawned :: Container -> RevertableProperty
nspawned c@(Container name (Chroot.Chroot loc system builderconf _) h) =
	RevertableProperty setup teardown
  where
	setup = combineProperties ("nspawned " ++ name) $
		map toProp steps ++ [containerprovisioned]
	teardown = combineProperties ("not nspawned " ++ name) $
		map (toProp . revert) (reverse steps)
	steps =
		[ enterScript c
		, chrootprovisioned
		, nspawnService c (_chrootCfg $ _chrootinfo $ hostInfo h)
		]

	-- Chroot provisioning is run in systemd-only mode,
	-- which sets up the chroot and ensures systemd and dbus are
	-- installed, but does not handle the other provisions.
	chrootprovisioned = Chroot.provisioned'
		(Chroot.propigateChrootInfo chroot) chroot True

	-- Use nsenter to enter container and and run propellor to
	-- finish provisioning.
	containerprovisioned = Chroot.propellChroot chroot
		(enterContainerProcess c) False

	chroot = Chroot.Chroot loc system builderconf h

-- | Sets up the service file for the container, and then starts
-- it running.
nspawnService :: Container -> ChrootCfg -> RevertableProperty
nspawnService (Container name _ _) cfg = RevertableProperty setup teardown
  where
	service = nspawnServiceName name
	servicefile = "/etc/systemd/system/multi-user.target.wants" </> service

	servicefilecontent = do
		ls <- lines <$> readFile "/lib/systemd/system/systemd-nspawn@.service"
		return $ unlines $
			"# deployed by propellor" : map addparams ls
	addparams l
		| "ExecStart=" `isPrefixOf` l =
			l ++ " " ++ unwords (nspawnServiceParams cfg)
		| otherwise = l
	
	goodservicefile = (==)
		<$> servicefilecontent
		<*> catchDefaultIO "" (readFile servicefile)

	writeservicefile = property servicefile $ makeChange $
		viaTmp writeFile servicefile =<< servicefilecontent

	setupservicefile = check (not <$> goodservicefile) $
		-- if it's running, it has the wrong configuration,
		-- so stop it
		stopped service
			`requires` daemonReloaded
			`requires` writeservicefile

	setup = started service `requires` setupservicefile

	teardown = check (doesFileExist servicefile) $
		disabled service `requires` stopped service

nspawnServiceParams :: ChrootCfg -> [String]
nspawnServiceParams NoChrootCfg = []
nspawnServiceParams (SystemdNspawnCfg ps) =
	M.keys $ M.filter id $ M.fromList ps

-- | Installs a "enter-machinename" script that root can use to run a
-- command inside the container.
--
-- This uses nsenter to enter the container, by looking up the pid of the
-- container's init process and using its namespace.
enterScript :: Container -> RevertableProperty
enterScript c@(Container name _ _) = RevertableProperty setup teardown
  where
	setup = combineProperties ("generated " ++ enterScriptFile c)
		[ scriptfile `File.hasContent`
			[ "#!/bin/sh"
			, "# Generated by propellor"
			, "pid=\"$(machinectl show " ++ shellEscape name ++ " -p Leader | cut -d= -f2)\" || true"
			, "if [ -n \"$pid\" ]; then"
			, "\tnsenter -p -u -n -i -m -t \"$pid\" \"$@\""
			, "else"
			, "\techo container not running >&2"
			, "\texit 1"
			, "fi"
			]
		, scriptfile `File.mode` combineModes (readModes ++ executeModes)
		]
	teardown = File.notPresent scriptfile
	scriptfile = enterScriptFile c

enterScriptFile :: Container -> FilePath
enterScriptFile (Container name _ _ ) = "/usr/local/bin/enter-" ++ mungename name

enterContainerProcess :: Container -> [String] -> CreateProcess
enterContainerProcess = proc . enterScriptFile

nspawnServiceName :: MachineName -> ServiceName
nspawnServiceName name = "systemd-nspawn@" ++ name ++ ".service"

containerDir :: MachineName -> FilePath
containerDir name = "/var/lib/container" </> mungename name

mungename :: MachineName -> String
mungename = replace "/" "_"

-- | This configures how systemd-nspawn(1) starts the container,
-- by specifying a parameter, such as "--private-network", or
-- "--link-journal=guest"
--
-- When there is no leading dash, "--" is prepended to the parameter.
--
-- Reverting the property will remove a parameter, if it's present.
containerCfg :: String -> RevertableProperty
containerCfg p = RevertableProperty (mk True) (mk False)
  where
	mk b = pureInfoProperty ("container configuration " ++ (if b then "" else "without ") ++ p') $
		mempty { _chrootinfo = mempty { _chrootCfg = SystemdNspawnCfg [(p', b)] } }
	p' = case p of
		('-':_) -> p
		_ -> "--" ++ p

-- | Bind mounts </etc/resolv.conf> from the host into the container.
--
-- This property is enabled by default. Revert it to disable it.
resolvConfed :: RevertableProperty
resolvConfed = containerCfg "bind=/etc/resolv.conf"
