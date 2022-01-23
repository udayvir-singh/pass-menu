INSTALL_DIR = /usr/local/bin

.PHONY: install uninstall

help:
	@echo "Pass-Menu v0.0-git"
	@echo
	@echo "Targets:"
	@echo "  :install         install pass-menu on this system."
	@echo "  :uninstall       uninstall pass-menu on this system."
	@echo
	@echo "Examples:"
	@echo "  make install"


root-check:
	@if [ `whoami` != "root" ]; then \
		echo "please run as root to continue..."; \
		exit 1; \
	fi

install: root-check
	install -m 0755 -v ./pass-menu.sh $(INSTALL_DIR)/pass-menu

uninstall: root-check
	rm -f $(INSTALL_DIR)/pass-menu
