# Kernel config fixups for Cavium ThunderX2 (TX2) systems.

CONFIG_THUNDER_NIC_VF=m
CONFIG_I2C_THUNDERX=m
CONFIG_THUNDER_NIC_VF=m
CONFIG_THUNDER_NIC_BGX=m
CONFIG_THUNDER_NIC_RGX=m
CONFIG_MDIO_THUNDER=m
CONFIG_SPI_THUNDERX=m

CONFIG_MODULE_SIG_KEY=""
CONFIG_SYSTEM_TRUSTED_KEYS=""

# Reserve space for a full relay triple:           xxx.xxx.xxx.xxx:xxxxx:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
CONFIG_CMDLINE="initrd=tci-initrd tci_relay_triple=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxz"
CONFIG_CMDLINE_FORCE=y
CONFIG_INITRAMFS_FORCE=n

# For QEMU testing
CONFIG_HW_RANDOM_VIRTIO=m

# Ethernet drivers
CONFIG_QED=m
CONFIG_QED_SRIOV=y
CONFIG_QEDE=m

CONFIG_BNX2X=m
CONFIG_BNX2X_SRIOV=y
