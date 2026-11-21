# luci-app-lalune

Architecture-independent LuCI frontend for the existing LaLune OpenWrt API.

The installer places the `root/` tree into `/`. LuCI authenticates the user;
`rpcd` ACL grants read-only status/profile inspection and write access to the
profile/connection actions. The executable rpcd plugin proxies a fixed,
allow-listed set of HTTP methods to `http://127.0.0.1:1062`; it does not accept
arbitrary URLs or shell commands.

The API remains available on the same port for LaLune Android and desktop
clients. This package adds LuCI as another frontend and does not replace or
change the remote client API.

For OpenWrt SDK builds, this directory is a standard `luci-app-*` package with
its Makefile. The LaLune installer currently installs the architecture-neutral
`root/` files directly from `luci-app-lalune.tar.gz`.
