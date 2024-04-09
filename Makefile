PREFIX  ?= ${HOME}/.local
BIN_DIR ?= $(PREFIX)/bin
MAN_DIR ?= $(PREFIX)/share/man/man1

ifndef VERBOSE
.SILENT:
endif

.ONESHELL:

# ---------------------- #
#          HELP          #
# ---------------------- #
help:
	echo 'Usage: make [VARIABLE] [TARGET] ...'
	echo
	echo 'Targets:'
	echo '  install    Install pass-menu on this system'
	echo '  uninstall  Uninstall pass-menu from this system'
	echo '  help       Print this help message and exit'
	echo
	echo 'Environment Variables:'
	echo '  PREFIX     Prefix for install paths (default: ~/.local)'
	echo '  BIN_DIR    Prefix for executable directory (default: $$PREFIX/bin)'
	echo '  MAN_DIR    Prefix for man pages directory (default: $$PREFIX/share/man/man1)'
	echo '  VERBOSE    Whether to print each command before executing'
	echo
	echo 'Examples:'
	echo '  make install'
	echo '  sudo make PREFIX=/usr install'


# ---------------------- #
#        INSTALL         #
# ---------------------- #
install:
	echo :: INSTALLING PASS MENU
	$(call install, 0755, ./pass-menu.bash, $(BIN_DIR)/pass-menu)
	$(call install, 0644, ./pass-menu.1, $(MAN_DIR)/pass-menu.1)
	echo :: DONE

uninstall:
	echo :: UNINSTALLING PASS MENU
	$(call remove, $(BIN_DIR)/pass-menu)
	$(call remove, $(MAN_DIR)/pass-menu.1)
	echo :: DONE


# ----------------------- #
#          UTILS          #
# ----------------------- #
define success
	echo -e "  \e[1;32m==>\e[0m"
endef

define failure
	echo -e "  \e[1;31m==>\e[0m"
endef

define install
	TMP_FILE=$$(mktemp)
	if install -D -m $(1) $(2) $(3) 2>$$TMP_FILE; then
		$(success) $(2)
	else
		$(failure) $(2)
		sed "s/^/      /" $$TMP_FILE
	fi
	rm $$TMP_FILE
endef

define remove
	TMP_FILE=$$(mktemp)
	if rm $(1) 2>$$TMP_FILE; then
		$(success) $(1)
	else
		$(failure) $(1)
		sed "s/^/      /" $$TMP_FILE
	fi
	rm $$TMP_FILE
endef
