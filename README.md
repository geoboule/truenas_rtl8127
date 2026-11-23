# truenas_rtl8127

Builds and installs the Realtek RTL8127 (r8127) driver on TrueNAS SCALE, whose
kernel does not include it. The build runs in a Docker container, so nothing is
installed on the host.

## Quick start

On the TrueNAS host, with Apps configured (Docker must be running):

```sh
sudo INSTALL_DIR=/mnt/YOUR_POOL/scripts POSTINIT=1 bash truenas_build_r8127_driver.sh
```

This builds the driver for the running kernel, installs it to `INSTALL_DIR`, and
registers a Post Init task that loads it at every boot. Reboot to load it, or add
`LOAD_MODULE=1` to load it now (not over the r8127 interface itself).

After every TrueNAS update, run the same command again: the module only loads on
the kernel it was built for.

## Before you update TrueNAS

If the RTL8127 is your only configured NIC, it stays down after an update until
the driver is rebuilt. Give another interface an address first (for example,
enable DHCP on the onboard NIC).

## More

All options (driver version, build directory, reload behaviour), how the boot
loader works, and the prerequisites are documented at the top of
[truenas_build_r8127_driver.sh](truenas_build_r8127_driver.sh).

Logs from the boot loader: `journalctl -t r8127`.
