Keystone Quick Install & Setup
===============================

This is a quick keystone deploying script

Please run as root

    # Install git (if necessary)
    apt-get install -y git
	cd /root
	git clone https://github.com/its-not-a-bug-its-a-feature/keystone_install.git
	cd keystone_install
	./install_keystone.sh {FLAVOUR}
e.g.
    ./install_keystone.sh precise-havana


If you specify a flavour, it must be either "precise-havana" or
"precise-grizzly". If you specify no flavour, the default keystone package for
your OS will be used.
