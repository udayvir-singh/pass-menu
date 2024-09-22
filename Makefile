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
	echo 'Usage: make [VARIABLES] [TARGETS]'
	echo
	echo 'Targets:'
	echo '  install    Install pass-menu on this system'
	echo '  uninstall  Uninstall pass-menu from this system'
	echo '  help       Print this help message and exit'
	echo
	echo 'Environment Variables:'
	echo '  PREFIX     Prefix for installation paths    (default: $$HOME/.local)'
	echo '  BIN_DIR    Directory for executables        (default: $$PREFIX/bin)'
	echo '  MAN_DIR    Directory for manual pages       (default: $$PREFIX/share/man/man1)'
	echo '  VERBOSE    Enable verbose command execution (default: <unset>)'
	echo
	echo 'Examples:'
	echo '  make install'
	echo '  sudo make PREFIX=/usr install'


# ---------------------- #
#        INSTALL         #
# ---------------------- #
install:
	echo :: INSTALLING PASS MENU
	$(call install, 0755, ./pass-menu.bash, "$(BIN_DIR)/pass-menu")
	$(call install, 0644, ./pass-menu.1, "$(MAN_DIR)/pass-menu.1")
	echo :: DONE

uninstall:
	echo :: UNINSTALLING PASS MENU
	$(call remove, "$(BIN_DIR)/pass-menu")
	$(call remove, "$(MAN_DIR)/pass-menu.1")
	echo :: DONE


# ----------------------- #
#          UTILS          #
# ----------------------- #
define exec
	TMP_FILE="$$(mktemp)"
	if $(1) 2> "$${TMP_FILE}"; then
		printf "  \033[1;32m==>\033[0m %s\n" $(2)
	else
		printf "  \033[1;31m==>\033[0m %s\n" $(2)
		sed "s/^/      /" "$${TMP_FILE}"
	fi
	rm "$${TMP_FILE}"
endef

define install
	$(call exec, install -Dm $(1) -- $(2) $(3), $(2))
endef

define remove
	$(call exec, rm -r -- $(1), $(1))
endef
