savedcmd_<EXTERNAL>/_work/kbuild/uvprobe/uvprobe.mod := printf '%s\n'   uvprobe.o | awk '!x[$$0]++ { print("<EXTERNAL>/_work/kbuild/uvprobe/"$$0) }' > <EXTERNAL>/_work/kbuild/uvprobe/uvprobe.mod
