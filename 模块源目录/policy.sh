#!/system/bin/sh
# 只修改本模块的单个设备策略键；不直接覆盖或删除共享 XML。
# 已核对 IOplusDevicePolicyManagerService：1=setData(String,String,int)->boolean，
# 4=getData(String,int)->String。不得把 service 命令退出 0 当成 Binder 成功。
# 接口证据（公开反编译，非官方源码）：
# https://github.com/HBYShyw/AntiThermal/blob/main/oplus-framework/sources/android/os/oplusdevicepolicy/IOplusDevicePolicyManagerService.java
# 调用方须持有 uv_lock；这里不重试，启动阶段由调用方有界等待服务。

UV_BK=${UV_BK:-/data/adb/uv2800_backup}

uv_policy_note() {
    if command -v uv_log >/dev/null 2>&1; then
        uv_log "$*" >&2
    else
        echo "uv2800: $*" >&2
    fi
}

# 解析 Android service 的完整 Parcel 文本。只接受本接口已知的最短返回：
# setter: exception=0 + bool=1；getter: exception=0 + UTF-16 true/false/null。
# 同时校验字数、字符串长度/终止符、逐行字节偏移及外围文本，避免把异常、
# 空响应、截断或其它接口的结果误判成功。AOSP 的 ASCII 展示列不参与解码。
uv_policy_parse() {
    awk -v kind="$1" '
    function fail() { bad=1; exit 1 }
    function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function hex(s, i,v,c) {
        s=tolower(s); v=0
        for(i=1;i<=length(s);i++) {
            c=index("0123456789abcdef",substr(s,i,1))-1
            if(c<0) fail()
            v=v*16+c
        }
        return v
    }
    {
        line=trim($0)
        if(line=="") next
        if(closed) fail()
        if(!started) {
            if(line !~ /^Result:[ \t]*Parcel\(/) fail()
            sub(/^Result:[ \t]*Parcel\(/,"",line)
            started=1
        }
        # Printable column in libutils HexDump is surrounded by single quotes.
        sub(/[ \t]+\047[^\047]*\047/,"",line)
        end=index(line,")")
        if(end) {
            if(trim(substr(line,end+1))!="") fail()
            line=substr(line,1,end-1); closed=1
        }
        line=trim(line)
        if(line ~ /^0x[0-9a-fA-F]+:/) {
            colon=index(line,":"); off=substr(line,3,colon-3)
            if(length(off)!=8 || hex(off)!=count*4) fail()
            line=trim(substr(line,colon+1))
            if(line=="") fail()
        }
        if(line=="") next
        n=split(line,parts,/[ \t]+/)
        for(i=1;i<=n;i++) {
            word=tolower(parts[i])
            if(length(word)!=8 || word ~ /[^0-9a-f]/ || ++count>5) fail()
            words[count]=word
        }
    }
    END {
        if(bad || !started || !closed || words[1]!="00000000") exit 1
        if(kind=="set") {
            if(count!=2 || words[2]!="00000001") exit 1
            print "true"; exit 0
        }
        if(kind!="get") exit 1
        if(count==2 && words[2]=="ffffffff") { print "absent"; exit 0 }
        if(count==5 && words[2]=="00000004" && words[3]=="00720074" &&
           words[4]=="00650075" && words[5]=="00000000") { print "true"; exit 0 }
        if(count==5 && words[2]=="00000005" && words[3]=="00610066" &&
           words[4]=="0073006c" && words[5]=="00000065") { print "false"; exit 0 }
        exit 1
    }'
}

# stdout 仅返回 true / false / absent；错误返回非零，不把 null 猜成成功 false。
uv_policy_read() {
    _upr_reply=$(su 1000 -c "service call oplusdevicepolicy 4 s16 oplus_diable_super_power_saving_mode i32 1" 2>&1) || return 1
    printf '%s\n' "$_upr_reply" | uv_policy_parse get
}

uv_policy_original() {
    _upo_value=$(cat "$UV_BK/policy_orig" 2>/dev/null) || return 1
    case "$_upo_value" in true|false|absent) printf '%s\n' "$_upo_value" ;; *) return 1 ;; esac
}

# 旧状态文件虽不再用于回写 XML，损坏时也不能被当作可迁移的正常备份。
uv_policy_legacy_valid() {
    [ -e "$UV_BK/orig_state" ] || return 0
    _upl_state=$(cat "$UV_BK/orig_state" 2>/dev/null) || return 1
    case "$_upl_state" in
        existed|absent) return 0 ;;
        *) uv_policy_note "旧策略 orig_state 无效，保留全部备份并停止"; return 1 ;;
    esac
}

# 先保存原键语义，再执行任何 setter；重复调用不覆盖首次备份。
uv_policy_save_original() {
    case "$1" in true|false|absent) ;; *) return 1 ;; esac
    case "$2" in live|legacy-default-false) ;; *) return 1 ;; esac
    if [ -e "$UV_BK/policy_orig" ]; then
        uv_policy_original >/dev/null
        return $?
    fi
    mkdir -p "$UV_BK" || return 1
    printf '%s\n' "$1" > "$UV_BK/policy_orig.tmp" &&
        printf '%s\n' "$2" > "$UV_BK/policy_orig_source.tmp" &&
        mv -f "$UV_BK/policy_orig_source.tmp" "$UV_BK/policy_orig_source" &&
        mv -f "$UV_BK/policy_orig.tmp" "$UV_BK/policy_orig"
}

uv_policy_set_verified() {
    case "$1" in true|false) ;; *) return 1 ;; esac
    _ups_target=$1
    _ups_before=$(uv_policy_read) || { uv_policy_note "设备策略读取失败，未调用 setter"; return 1; }
    # 已处于目标状态时无需 setter；这同样是一条本次实时读取证据。
    [ "$_ups_before" = "$_ups_target" ] && return 0
    _ups_reply=$(su 1000 -c "service call oplusdevicepolicy 1 s16 oplus_diable_super_power_saving_mode s16 $_ups_target i32 1" 2>&1) || {
        uv_policy_note "设备策略 setter 进程失败"; return 1;
    }
    printf '%s\n' "$_ups_reply" | uv_policy_parse set >/dev/null || {
        uv_policy_note "设备策略 setter 响应异常或返回 false"; return 1;
    }
    _ups_after=$(uv_policy_read) || { uv_policy_note "设备策略写后读取失败"; return 1; }
    [ "$_ups_after" = "$_ups_target" ] || {
        uv_policy_note "设备策略读回 $_ups_after，期望 $_ups_target"; return 1;
    }
}

uv_policy_apply() {
    uv_policy_legacy_valid || return 1
    _upa_live=$(uv_policy_read) || { uv_policy_note "设备策略原值读取失败，保留原备份"; return 1; }
    if [ ! -e "$UV_BK/policy_orig" ]; then
        if [ -e "$UV_BK/applied" ] || [ -e "$UV_BK/orig_state" ] || [ -e "$UV_BK/devicepolicy_orig.xml" ]; then
            # 旧版只有整份 XML，当前 true 也可能是模块自身设置，不能作为原值。
            # 不猜 XML 格式、不重放旧文件；明确采用该功能的默认 false 语义。
            uv_policy_note "迁移旧版策略备份：原键未独立记录，采用明确默认 false；旧 XML 仅保留"
            uv_policy_save_original false legacy-default-false || return 1
        else
            uv_policy_save_original "$_upa_live" live || return 1
        fi
    else
        uv_policy_original >/dev/null || { uv_policy_note "原策略键备份无效，停止应用"; return 1; }
    fi
    uv_policy_set_verified true
}

uv_policy_restore() {
    uv_policy_legacy_valid || return 1
    if [ ! -e "$UV_BK/policy_orig" ]; then
        # 旧版本未备份单个键。先确认接口可读取，再记录清晰的迁移假设。
        uv_policy_read >/dev/null || { uv_policy_note "设备策略服务尚不可读取，保留旧备份"; return 1; }
        uv_policy_note "旧版未记录原策略键，按明确默认 false 恢复；不改写共享 XML"
        uv_policy_save_original false legacy-default-false || return 1
    fi
    _upr_original=$(uv_policy_original) || { uv_policy_note "原策略键备份无效，停止恢复"; return 1; }
    case "$_upr_original" in
        absent)
            # 只使用已验证的事务 1/4；没有调用 removeData 或传入猜测的 null。
            # null 与 false 对本开关具有相同默认效果，但存储状态并不相同。
            uv_policy_note "原策略键缺失：恢复为显式 false（默认效果），不声称删除该键"
            _upr_target=false ;;
        *) _upr_target=$_upr_original ;;
    esac
    uv_policy_set_verified "$_upr_target"
}
