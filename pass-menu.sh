#!/usr/bin/env bash

set +x
readonly VERSION="v0.0 git"

MODE=""
MENUCMD=""
TIMEOUT="45"
STOREDIR="${PASSWORD_STORE_DIR-$HOME/.password-store}"

if [ ${WAYLAND_DISPLAY} ]; then
	if type ydotool &>/dev/null; then
		DOTOOL="ydotool type --file /dev/stdin"
	else
		DOTOOL="wtype -"
	fi
	CLIPSET="wl-copy"
	CLIPGET="wl-paste"
else
	DOTOOL="xdotool type --clearmodifiers --file -"
	CLIPSET="xclip -selection clipboard"
	CLIPGET="${CLIPSET} -o"
fi

# ---------------------- #
#          INFO          #
# ---------------------- #
function show-help {
	echo \
"Usage: pass-menu [Option] -- COMMAND [ARGS]

Options:
  -p, --path              path to password store
  -c, --clip              copy output to clipboard
      --timeout           timeout for clearing clipboard [default: 45]
  -t, --type              type the output, useful in GUI applications 
  -e, --echo              print output to standard output
  -h, --help              display this help and exit
  -v, --version           output version information and exit

Examples:
	pass-menu --clip --timeout 15 -- fzf
	pass-menu --type              -- dmenu -i -l 15"

	exit 0
}

function show-version {
	echo "${VERSION}"
	exit 0
}

function error {
	local  MSG="${1}"; shift 1
	local ARGS="${@}"

	printf "pass-menu: ${MSG}\n" ${ARGS} >&2
	exit 1
}

# ---------------------- #
#          OPTS          #
# ---------------------- #
function set-opt-path {
	local OPTION="${1}"

	if [[ ! -d "${OPTION}" ]]; then
		error '--path "%s" is not a valid directory.' "${OPTION}" 
	fi

	STOREDIR="${OPTION}"
}

function set-opt-mode {
	local OPTION="${1}"

	if [[ "${MODE}" && "${MODE}" != "${OPTION}" ]]; then
		error 'conflicting option "--%s" with "--%s"' "${OPTION}" "${MODE}"
	fi

	MODE="${OPTION}"
}

function set-opt-timeout {
	local OPTION="${1}"

	if [[ ! "${OPTION}" =~ ^-?[0-9]+$ ]]; then
		error '"--timeout" must be an integer'
	elif [[ "${OPTION}" -lt 10 ]]; then
		error '"--timeout" must be greater than 10'
	fi
	
	TIMEOUT="${OPTION}"
}

function set-opt-cmd {
	local OPTION="${*}"

	MENUCMD="${OPTION}"
}

function opt-error {
	local OPTION="${1}"

	error 'invalid option "%s"' "${OPTION}"
}

while [ -n "${1}" ]; do
	case "${1}" in
		-p | --path)      set-opt-path "${2}"; shift 2 ;;
		-c | --clip)      set-opt-mode 'clip'; shift 1 ;;
		-t | --type)      set-opt-mode 'type'; shift 1 ;;
		-e | --echo)      set-opt-mode 'echo'; shift 1 ;;
		     --timeout)   set-opt-timeout "${2}" ; shift 2 ;;
		-h | --help)      show-help ;;
		-v | --version)   show-version ;;
		--)               shift; set-opt-cmd "${@}"; break ;;
		*)                opt-error "${1}" ;;
	esac
done

if [[ ! "${MENUCMD}" ]]; then
	error "missing required argument COMMAND"
fi

# ---------------------- #
#         UTILS          #
# ---------------------- #
function clip-copy {
	local VALUE="${1}"
	local ORIG="$(${CLIPGET})"
	local MSG="Copied to clipboard. Will clear in ${TIMEOUT} seconds."
	
	printf "${VALUE}" | ${CLIPSET}
	printf "%s\n" "${MSG}"

	if type notify-send &>/dev/null; then
		notify-send "${MSG}"
	fi

	{
		sleep "${TIMEOUT}" || exit 1
		# restore clipboard back to orginal if it hasn't changed.
		if [[ "$(${CLIPGET})" == "${VALUE}" ]]; then
			printf "${ORIG}" | ${CLIPSET}
		fi
	} &
}

function dotool-type {
	local VALUE="${1}"

	printf "${VALUE}" | ${DOTOOL}
}

# ---------------------- #
#          MAIN          #
# ---------------------- #
function get-pass-files {
	local LIST

	shopt -s nullglob globstar
	LIST=("$STOREDIR"/**/*.gpg)
	LIST=("${LIST[@]#"$STOREDIR"/}")
	LIST=("${LIST[@]%.gpg}")

	printf "%s\n" "${LIST[@]}" 
}

function get-pass-keys {
	local PASS_NAME="${1}"
	local PASS_FILE="$(pass "${PASS_NAME}")"
	
	if [[ ${#PASS_FILE} -lt 3 ]]; then
		error '"%s" is too short.' "${PASS_NAME}" 
	fi

	# Parse Action First
	awk '
	/action(.+)/ { 
		match($1, /action\((.+)\)/, a)
		printf "((%s))\n", a[1]
	}' <<< "${PASS_FILE}"

	# Parse Rest of Keys
	awk '
	BEGIN { 
		FS=": +"
		password="Yes" 
	} 

	NR == 1 && ! $2 { print "Password"; password=Null } 

	$2 { 
		sub("^ +", "", $1)
		if ( $1 == "Password") {
			if (password) print $1
		} else {
			print $1
		}
	}

	/^ *otpauth:/ { print "OTP" }' <<< "${PASS_FILE}"
}

function get-pass-value {
	local PASS_NAME="${1}"
	local PASS_KEY="${2}"

	case "${PASS_KEY}" in 
	OTP)      
		pass otp "${PASS_NAME}" 
	;;

	Password) 
		pass "${PASS_NAME}" | awk '
		BEGIN { 
			FS=": +"
			password="Yes" 
		} 

		NR == 1 && ! $2 { print $1; password=Null } 

		/Password/ && $2 { if (password) print $2 }'
	;;

	*) 
		pass "${PASS_NAME}" | awk -v key="${PASS_KEY}" '
		BEGIN { FS=": +" }

		$2 {
			if ($1 ~ key)
				for (i=2; i<=NF; i++) print $i
		}' 
	;;
	esac
}

function get-action {
	local PASS_NAME="${1}"
	local  ACT_NAME="${2}"

	pass "${PASS_NAME}" | awk -v action="action.+${ACT_NAME}" '{
		if ($1 ~ action) 
			for (i=2; i<=NF; i++) print $i
	}'
}

function execute-action {
	local PASS_NAME="${1}"
	shift

	while [ -n "${1}" ]; do
		case "${1}" in
		:clip)
			clip-copy "$(get-pass-value "${PASS_NAME}" "${2}")"
			shift 2
			;;
		:type)
			dotool-type "$(get-pass-value "${PASS_NAME}" "${2}")"
			shift 2
			;;
		:tab)
			dotool-type "	"
			shift 1
			;;
		:sleep)
			sleep "${2}"
			shift 2
			;;

		:exec | :notify)
			local ACT="${1}"
			local STR="${2:1}"
			shift 2
			# Parse String
			while [ ! "${STR:(-1)}" = '"' ]; do
				if [ -z "${1}" ]; then
					error 'unmatched {"} in %s.' "${PASS_NAME}"
				fi

				STR="${STR} ${1}"
				shift 1
			done

			STR="${STR::(-1)}"

			if [ "${ACT}" = ":exec" ]; then
				sh -c "${STR}"
			else
				notify-send "${STR}"
			fi
			;;

		:*) error "invalid action %s in %s" "${1}" "${PASS_NAME}" ;;
		*)  error "invalid param %s in %s" "${1}" "${PASS_NAME}" ;;
		esac
	done
}

function get-mode {
	if [[ "${MODE}" ]]; then
		printf "${MODE}"
	else
		local CANDIDATES="clip\ntype\necho"
		printf "${CANDIDATES}" | ${MENUCMD}
	fi
}

function call-menu {
	local PIPE="$(< /dev/stdin)"

	[ -z "${PIPE}" ] && exit 1

	printf "${PIPE}" | ${MENUCMD}
}

function main {
	local PASS_NAME PASS_KEY OUT

	PASS_NAME=$(get-pass-files | call-menu)
	[[ ! ${PASS_NAME} ]] && exit 1

	PASS_KEY=$(get-pass-keys "${PASS_NAME}" | call-menu)
	[[ ! ${PASS_KEY} ]] && exit 1

	if [ "${PASS_KEY:(-2)}" = "))" ]; then
		execute-action "${PASS_NAME}" $(get-action "${PASS_NAME}")
		return 0
	fi

	OUT=$(get-pass-value "${PASS_NAME}" "${PASS_KEY}")

	case "$(get-mode)" in
		clip) clip-copy "${OUT}" ;;
		type) dotool-type "${OUT}" ;;
		echo) printf "${OUT}" ;;
	esac
}

main
