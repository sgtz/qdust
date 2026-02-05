# Path to Q executable (override to skip auto-detection)
# export QDUST_Q="/path/to/q"

# OS detection for Q binary path: m=mac, l=linux, w=windows
if [[ -z "$QOS" ]]; then
  case "$(uname -s)" in
    Darwin)          export QOS="m" ;;
    Linux)           export QOS="l" ;;
    CYGWIN*|MINGW*)  export QOS="w" ;;
    *)               export QOS="l" ;;
  esac
fi

# set if needed
# export QHOME=""
# export QLIC=""

# rlwrap 
# QDUST_RLWRAP_OPTS: flags (default: -A -pYELLOW -c -r -H ~/.qhistory)
# export QDUST_RLWRAP=/usr/local/bin/rlwrap
# export QDUST_RLWRAP_OPTS="-A -pYELLOW -c -i -r -H ~/.qhistory"