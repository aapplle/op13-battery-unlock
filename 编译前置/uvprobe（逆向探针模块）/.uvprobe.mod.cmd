savedcmd_<WORKSPACE>/_work/kbuild/uvprobe/uvprobe.mod := printf '%s\n'   uvprobe.o | awk '!x[$$0]++ { print("<WORKSPACE>/_work/kbuild/uvprobe/"$$0) }' > <WORKSPACE>/_work/kbuild/uvprobe/uvprobe.mod
