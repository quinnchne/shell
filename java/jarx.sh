_get_jar_pids() {
    if [ -z "$1" ]; then
        echo 'Usage: _get_jar_pids <JAR>'
        return 1
    fi

    # local jar_pids=(`ps -efal | grep "$1" | grep -v "grep" | awk '{print $2}'`)
    # 1) 只用文件名匹配：同一个 jar 可能以相对路径（jar/x.jar）或绝对路径启动，
    #    用户传入的路径写法不一定与进程命令行里的一致
    # 2) 如果服务器中有同名的 jar，stop 和 restart 会把它们都当成同一个，注意区分文件名
    local jar_name="$(basename -- "$1")"
    local pid arg0
    local jar_pids=()

    for pid in $(pgrep -f -- "$jar_name"); do
        # 3) 只保留 java 进程：命令行里碰巧带有文件名的 tail / vim，甚至当前正在执行
        #    `bash -c '... jarx stop xxx.jar'` 的 shell 本身，都不能算 jar 进程，
        #    否则 stop 会把它们一起 kill -9
        arg0=""
        IFS= read -r -d '' arg0 2>/dev/null < "/proc/$pid/cmdline"
        [ "${arg0##*/}" = "java" ] && jar_pids+=("$pid")
    done

    echo "${jar_pids[@]}"
}

_is_jar_pid_exists() {
    if [ -z "$1" ]; then
        echo 'Usage: _is_jar_pid_exists <JAR>'
        return 1
    fi

    local jar_pids=(`_get_jar_pids "$1"`)

    if [ ${#jar_pids[@]} -ne 0 ]; then
        return 0
    fi
    return 1
}

_print_jar_start_result() {
    if [ -z "$1" ]; then
        echo 'Usage: _print_jar_start_result <JAR> [PID]'
        return 1
    fi

    local max_wait=120
    local wait_time=2

    sleep 2

    while [ $wait_time -lt $max_wait ]; do
        # 刚启动的进程已经退出，说明启动失败，没必要继续等
        if [ -n "$2" ] && ! kill -0 "$2" 2>/dev/null; then
            # 取回刚启动的进程的退出码（它是当前 shell 的子进程）：
            #   137 = 被 SIGKILL 杀掉（内存不足时常见于 OOM killer），1 = JVM / 应用自身报错，127 = 找不到 java
            local rc=0 hint=""
            wait "$2" 2>/dev/null || rc=$?
            if [ $rc -eq 137 ]; then
                hint="，被 SIGKILL 杀掉，常见原因是内存不足: dmesg -T | grep -i -E 'out of memory|killed process'"
            fi
            echo "[$1] start failed ❌ (process exited, exit code $rc$hint)，可加 -fg 前台启动查看报错"
            return 1
        fi
        if _is_jar_pid_exists "$1"; then
            echo "[$1] start ok! ✅ "
            return 0
        fi
        # 进度只在终端里显示；非终端（systemd / 重定向）下不输出，避免日志里每秒一行
        if [ -t 1 ]; then
            echo "starting... ($((wait_time + 1))/$max_wait s)"
        fi
        sleep 1
        ((wait_time++))
    done
    
    echo "[$1] start timeout ❌ "
    return 1 
}

_stop_jar_srv() {
    if [ -z "$1" ]; then
        echo 'Usage: _stop_jar_srv <JAR>'
        return 1
    fi

    local pid
    local jar_pids=(`_get_jar_pids "$1"`)

    if [ ${#jar_pids[@]} -eq 0 ]; then
        echo "[$1] not start ❌ "
        return 1
    fi

    for pid in "${jar_pids[@]}"; do
        if [ -n "$pid" ]; then
            kill -9 $pid
            echo "killed [$pid] ok! ✅ "
        fi
    done

    # kill -9 是异步的：等旧进程真正退出（端口、文件锁等资源释放）后再返回，
    # 否则紧接着 restart 时，新进程可能因端口仍被占用而秒退
    local waited=0
    while [ -n "$(_get_jar_pids "$1")" ] && [ $waited -lt 10 ]; do
        sleep 1
        waited=$((waited + 1))
    done

    if [ -n "$(_get_jar_pids "$1")" ]; then
        echo "[$1] stop timeout ❌ "
        return 1
    fi

    echo "[$1] stop ok! ✅ "
}

# 后台启动时 java 的 stdout/stderr 去向：默认丢弃（jar 自己会把日志写到文件）。
# 排查"启动后很快退出"这类问题时，可设置环境变量 JARX_OUT_DIR=<绝对路径目录>，
# 输出会写到 <JARX_OUT_DIR>/<jar文件名>.out（每次启动覆盖）。应用在日志框架初始化之前的报错
# （如连不上 Nacos 取配置）只会出现在 stdout/stderr 里
_jarx_out_file() {
    if [ -z "$JARX_OUT_DIR" ] || ! mkdir -p -- "$JARX_OUT_DIR" 2>/dev/null; then
        echo /dev/null
        return
    fi
    echo "$JARX_OUT_DIR/$(basename -- "$1").out"
}

# 前台运行 java（不使用 nohup / &），适合被 systemd 等进程管理器拉起
# 不重定向输出：java 的 stdout/stderr 直接输出到终端（systemd 下进 journald）
# - 非交互 shell：用 exec 替换当前 shell，让 java 成为主进程，直接接收 SIGTERM
# - 交互式 shell：普通前台运行（exec 会把你的终端一起替换掉），Ctrl+C 可停止
_run_jar_fg() {
    if [[ $- == *i* ]]; then
        java "$@"
    else
        exec java "$@"
    fi
}

_start_jar_srv() {
    local foreground=0
    if [ "$1" = "-fg" ]; then
        foreground=1
        shift
    fi

    if [ -z "$1" ]; then
        echo 'Usage: _start_jar_srv [-fg] <JAR> [PORT]'
        return 1
    fi

    # jar 不存在时 java 会立刻以退出码 1 退出，只看退出码很难发现是路径写错，这里提前明确报出
    if [ ! -f "$1" ]; then
        echo "[$1] jar not found ❌ "
        return 1
    fi

    # 仅在本函数及其子进程内生效，避免污染调用者（交互式）shell 的环境
    local -x LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

    echo "[$1] starting..."

    local JAVA_OPTS="-Xms1g \
    -Xmx1g \
    -XX:+UseG1GC \
    -XX:MaxGCPauseMillis=200 \
    -XX:InitiatingHeapOccupancyPercent=35 \
    -XX:+AlwaysPreTouch \
    -Dfile.encoding=UTF-8" 

    if [ -n "$2" ]; then
       JAVA_OPTS="$JAVA_OPTS -Dserver.port=$2"
    fi

    if [ $foreground -eq 1 ]; then
        _run_jar_fg $JAVA_OPTS -jar "$1"
        return $?
    fi

    nohup java $JAVA_OPTS -jar "$1" &> "$(_jarx_out_file "$1")" &

    _print_jar_start_result "$1" $!
}

_start_jar_srv_cloud() {
    local foreground=0
    if [ "$1" = "-fg" ]; then
        foreground=1
        shift
    fi

    if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ] || [ -z "$5" ] || [ -z "$6" ]; then
        printf "%25s: %s\n" "Usage" "_start_jar_srv_cloud [-fg] <JAR> \\"
        printf "%25s: %s\n" "" "<NACOS_LOGS_PATH> \\"
        printf "%25s: %s\n" "" "<NACOS_SNAPSHOTS_PATH> \\"
        printf "%25s: %s\n" "" "<NACOS_CFG_NAMESPACE> \\"
        printf "%25s: %s\n" "" "<NACOS_SRV_NAMESPACE> \\"
        printf "%25s: %s\n" "" "<SENTINEL_LOGS_PATH>\\"
        printf "%25s: %s\n" "" "[PORT]"
        return 1
    fi

    if [ ! -f "$1" ]; then
        echo "[$1] jar not found ❌ "
        return 1
    fi

    # 仅在本函数及其子进程内生效，避免污染调用者（交互式）shell 的环境
    local -x LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

    echo "---------------------------------------------------------------------------------"
    printf "%25s: %s\n" "JAR" "$1"
    printf "%25s: %s\n" "NACOS_LOGS_PATH" "$2"
    printf "%25s: %s\n" "NACOS_SNAPSHOTS_PATH" "$3"
    printf "%25s: %s\n" "NACOS_CFG_NAMESPACE" "$4"
    printf "%25s: %s\n" "NACOS_SRV_NAMESPACE" "$5"
    printf "%25s: %s\n" "SENTINEL_LOGS_PATH" "$6"
    printf "%25s: %s\n" "PORT" "$7"
    echo "---------------------------------------------------------------------------------"

    echo "starting..."

    local JAVA_OPTS="-Xms1g \
    -Xmx1g \
    -XX:+UseG1GC \
    -XX:MaxGCPauseMillis=200 \
    -XX:InitiatingHeapOccupancyPercent=35 \
    -XX:+AlwaysPreTouch \
    -Dfile.encoding=UTF-8 \
    -Dspring.cloud.nacos.config.namespace=$4 \
    -Dspring.cloud.nacos.discovery.namespace=$5 \
    -DJM.LOG.PATH=$2 \
    -DJM.SNAPSHOT.PATH=$3 \
    -Dcsp.sentinel.log.dir=$6" 

    if [ -n "$7" ]; then
       JAVA_OPTS="$JAVA_OPTS -Dserver.port=$7"
    fi

    if [ $foreground -eq 1 ]; then
        _run_jar_fg ${JAVA_OPTS} -jar "$1"
        return $?
    fi

    nohup java ${JAVA_OPTS} -jar "$1" &> "$(_jarx_out_file "$1")" &

    _print_jar_start_result "$1" $!
}

# 按目录约定批量启动某个项目下的 cloud jar（后台方式；加 -fg 时只能给一个 jar）
# 用法: _start_project_jars [-fg] <ROOT_DIR> <NS_ID> <JAR文件名>...
#
# 约定的目录结构（<name> 为 jar 文件名去掉 .jar 和版本号后的部分，
# 如 vpcs-biz-web-0.0.1.jar -> vpcs-biz-web）：
#   <ROOT_DIR>/jar/<JAR文件名>
#   <ROOT_DIR>/nacos/<name>/logs
#   <ROOT_DIR>/nacos/<name>/snapshots
#   <ROOT_DIR>/sentinel/logs/csp
# 启动前会先进入 <ROOT_DIR>：jar 里用相对路径输出的文件（如日志）才会生成在 <ROOT_DIR> 下，
# 而不是调用者所在的目录（systemd 拉起时是 /）
# 某个 jar 启动失败时继续启动后面的，最后返回 1
_start_project_jars() {
    local fg_opt=""
    if [ "$1" = "-fg" ]; then
        fg_opt="-fg"
        shift
    fi

    if [ $# -lt 3 ] || [ -z "$1" ] || [ -z "$2" ]; then
        echo 'Usage: _start_project_jars [-fg] <ROOT_DIR> <NS_ID> <JAR>...'
        return 1
    fi

    if [ -n "$fg_opt" ] && [ $# -gt 3 ]; then
        echo "-fg 只能用于单个 jar（前台启动会占用当前进程，后面的 jar 无法继续启动）"
        return 1
    fi

    # 转成绝对路径：cd 之后，相对路径的 ROOT_DIR 就失效了
    local root
    root="$(cd -- "$1" 2>/dev/null && pwd)" || {
        echo "jarx: ROOT_DIR not found: $1"
        return 1
    }
    local ns="$2"
    shift 2

    if [ -n "$fg_opt" ] && [[ $- != *i* ]]; then
        # -fg + 非交互 shell（systemd）：后面会 exec java 替换当前 shell，
        # 所以必须直接在当前 shell 里 cd（放进子 shell，java 就不是主进程了）
        cd "$root" || return 1
        _start_project_jars_in_cwd "$fg_opt" "$root" "$ns" "$@"
    else
        # 其余情况放进子 shell：不会改变调用者（交互式）shell 的当前目录，
        # 中途按 Ctrl+C 也不会把调用者留在 ROOT_DIR
        ( cd "$root" && _start_project_jars_in_cwd "$fg_opt" "$root" "$ns" "$@" )
    fi
}

# _start_project_jars 的实际循环：在当前目录（调用者已切到 ROOT_DIR）下逐个启动
_start_project_jars_in_cwd() {
    local fg_opt="$1" root="$2" ns="$3"
    shift 3

    local jar name rc=0
    for jar in "$@"; do
        name="${jar%.jar}"
        name="${name%-[0-9]*}"
        _start_jar_srv_cloud $fg_opt "$root/jar/$jar" \
            "$root/nacos/$name/logs" \
            "$root/nacos/$name/snapshots" \
            "$ns" "$ns" \
            "$root/sentinel/logs/csp" || rc=1
    done

    return $rc
}

# 复用正在运行的 java 进程的完整启动命令（/proc/<pid>/cmdline）和工作目录来重启，
# 这样重启时不需要再传 PORT、Nacos 等启动参数，也不会漏写 -cloud 对应的 -D 选项
# 注意：只复用命令行和工作目录，不复用原进程的环境变量
_restart_jar_srv() {
    if [ -z "$1" ]; then
        echo 'Usage: _restart_jar_srv <JAR>'
        return 1
    fi

    local pid arg prev has_jar jar_arg cwd target_pid target_jar
    local found=0
    local -a args=() cmd=()

    for pid in $(_get_jar_pids "$1"); do
        args=()
        while IFS= read -r -d '' arg; do
            args+=("$arg")
        done 2>/dev/null < "/proc/$pid/cmdline"

        # 只认 "java ... -jar xxx.jar" 形式的进程，忽略 tail / vim 等碰巧带有文件名的进程
        [ "${args[0]##*/}" = "java" ] || continue

        prev=""
        has_jar=0
        jar_arg=""
        for arg in "${args[@]}"; do
            if [ "$prev" = "-jar" ]; then
                has_jar=1
                jar_arg="$arg"
            fi
            prev="$arg"
        done
        [ $has_jar -eq 1 ] || continue

        found=$((found + 1))
        target_pid=$pid
        target_jar="$jar_arg"
        cmd=("${args[@]}")
    done

    if [ $found -eq 0 ]; then
        echo "[$1] not start ❌ , 没有可复用的启动命令，请用 jarx start 启动"
        return 1
    fi

    if [ $found -gt 1 ]; then
        echo "[$1] found $found java processes ❌ , 无法确定复用哪一个，请传完整参数: jarx restart [-cloud] <JAR> <参数...>"
        return 1
    fi

    cwd=$(readlink "/proc/$target_pid/cwd" 2>/dev/null)
    if [ -z "$cwd" ]; then
        echo "[$1] cannot read cwd of pid $target_pid ❌ , 请传完整参数: jarx restart [-cloud] <JAR> <参数...>"
        return 1
    fi

    # 先确认 jar 还在（相对路径相对于原进程的工作目录），否则停掉旧进程后就再也起不来了
    if ! ( cd "$cwd" && [ -f "$target_jar" ] ); then
        echo "[$1] jar not found ❌ : $target_jar (cwd: $cwd)，未停止原进程"
        return 1
    fi

    echo "[$1] restart with:"
    echo "  cwd: $cwd"
    echo "  cmd: ${cmd[*]}"

    # 必须在 stop 之前读取（stop 之后 /proc/<pid> 就没了）
    _stop_jar_srv "$1" || return 1

    # 仅在本函数及其子进程内生效，避免污染调用者（交互式）shell 的环境
    local -x LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

    echo "[$1] starting..."

    # 子 shell 里 cd + exec：不改变当前 shell 的目录，且 $! 就是 java 进程的 PID
    local out_file
    out_file="$(_jarx_out_file "$1")"
    ( cd "$cwd" && exec nohup "${cmd[@]}" &> "$out_file" ) &

    _print_jar_start_result "$1" $!
}

# 单次探测一个端点：
#   HOST:PORT                 TCP 能连上即成功
#   http://HOST[:PORT]/PATH   HTTP 返回 200 才成功（纯 bash /dev/tcp，不依赖 curl）
# 端口刚打开不代表服务已就绪（如 Nacos），需要时用 http:// 形式检查 readiness 接口
_jarx_probe_endpoint() {
    local ep="$1" rest hostport host port path

    if [[ "$ep" == http://* ]]; then
        rest="${ep#http://}"
        hostport="${rest%%/*}"
        if [[ "$rest" == */* ]]; then path="/${rest#*/}"; else path="/"; fi
        host="${hostport%%:*}"
        port="${hostport##*:}"
        [ "$port" = "$hostport" ] && port=80
        # 最多等 5 秒，避免对端不响应时卡住
        timeout 5 bash -c '
            exec 3<>"/dev/tcp/$0/$1" || exit 1
            printf "GET %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n" "$2" "$0" >&3
            IFS= read -r line <&3
            [[ "$line" == "HTTP/"*" 200"* ]]
        ' "$host" "$port" "$path" 2>/dev/null
    else
        # 最多等 3 秒，避免对端丢包时卡住
        timeout 3 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "${ep%:*}" "${ep##*:}" 2>/dev/null
    fi
}

# 等待一个或多个端点就绪（如 Nacos 开机后需要一段时间才就绪）
# 用法: _wait_ports [-t 超时秒数] <HOST:PORT | http://HOST[:PORT]/PATH>...   （默认超时 120 秒）
# 全部就绪时返回 0；超时返回 1
_wait_ports() {
    local max_wait=120
    if [ "$1" = "-t" ]; then
        max_wait="$2"
        shift 2
    fi

    local usage='Usage: jarx wait-port [-t SECONDS] <HOST:PORT | http://HOST[:PORT]/PATH>...'
    if [ $# -eq 0 ] || ! [[ "$max_wait" =~ ^[0-9]+$ ]]; then
        echo "$usage"
        return 1
    fi
    local ep_check
    for ep_check in "$@"; do
        if ! [[ "$ep_check" == http://?* || "$ep_check" =~ ^[^:/]+:[0-9]+$ ]]; then
            echo "jarx: invalid endpoint '$ep_check'"
            echo "$usage"
            return 1
        fi
    done

    local start=$SECONDS elapsed ep last_report=0
    local -a pending=()

    echo "waiting for: $* (timeout ${max_wait}s)"

    while true; do
        pending=()
        for ep in "$@"; do
            _jarx_probe_endpoint "$ep" || pending+=("$ep")
        done

        elapsed=$((SECONDS - start))

        if [ ${#pending[@]} -eq 0 ]; then
            echo "ready ✅ (waited ${elapsed}s)"
            return 0
        fi

        if [ $elapsed -ge $max_wait ]; then
            echo "not ready after ${max_wait}s ❌ : ${pending[*]}"
            return 1
        fi

        # 每 30 秒报告一次，方便在 journal 里看到还在等什么
        if [ $((elapsed - last_report)) -ge 30 ]; then
            echo "still waiting (${elapsed}s): ${pending[*]}"
            last_report=$elapsed
        fi

        sleep 2
    done
}

_jarx_usage() {
    cat <<'USAGE'
Usage:
  jarx start   [-fg] <JAR> [PORT]            启动普通 jar
  jarx start   [-fg] -cloud <JAR> <NACOS_LOGS_PATH> <NACOS_SNAPSHOTS_PATH> \
                      <NACOS_CFG_NAMESPACE> <NACOS_SRV_NAMESPACE> \
                      <SENTINEL_LOGS_PATH> [PORT]   启动 cloud jar
  jarx start   [-fg] -cloud -root <ROOT_DIR> -ns <NS_ID> <JAR文件名>...
                                             按目录约定批量启动 cloud jar (-fg 时只能给一个 jar)
  jarx stop    <JAR>...                      停止 jar (可同时给多个)
  jarx restart <JAR>                         重启：复用正在运行进程的完整启动命令，不用再加参数选项
  jarx restart [-cloud] <JAR> <参数...>      重启：如果参数选项有变，可以再显式给定参数重启 (参数同 start, 不支持 -fg)
  jarx pids    <JAR>                         查看 jar 的 PID
  jarx wait-port [-t SECONDS] <HOST:PORT | http://HOST[:PORT]/PATH>...
                                             等待一个或多个端点就绪 (默认超时 120 秒)：
                                             HOST:PORT 表示 TCP 能连上；http:// 地址要求返回 200
                                             如: jarx wait-port -t 180 http://127.0.0.1:8848/nacos/v1/console/health/readiness

Options:
  -cloud   使用 cloud jar 包的启动参数
  -fg      前台启动 (不使用 nohup / &，输出到终端)，适合 systemd 托管
  -root    项目父级目录 <ROOT_DIR>，jar / Nacos / Sentinel 的目录均按下面的"目录约定"推导
  -ns      Nacos 配置命名空间和服务命名空间 (两者取同一个值)

目录约定 (jarx start -cloud -root ... 批量启动时)：
  <name> 是 jar 文件名去掉 .jar 和版本号后的部分，
  如 vpcs-biz-web-0.0.1.jar -> vpcs-biz-web

  jar 路径      : <ROOT_DIR>/jar/<jar 文件名>
  Nacos 日志    : <ROOT_DIR>/nacos/<name>/logs
  Nacos 快照    : <ROOT_DIR>/nacos/<name>/snapshots
  Sentinel 日志 : <ROOT_DIR>/sentinel/logs/csp

  启动前会先进入 <ROOT_DIR>，jar 中使用相对路径输出的文件 (如日志) 会生成在 <ROOT_DIR> 下

Environment:
  JARX_OUT_DIR   排查启动问题用：设置后，后台启动 java 的 stdout/stderr 会写到
                 <JARX_OUT_DIR>/<jar文件名>.out (每次启动覆盖，请用绝对路径)；默认丢弃
                 例：如果是启动 cloud 的 jar 包，启动时会先去连 nacos 服务，如果此时 nacos 服务
                 未启动，jar 包自己的日志目录都不会生成，严重影响 jar 包启动失败原因排查
USAGE
}

jarx() {
    local cmd="$1"

    if [ $# -eq 0 ]; then
        _jarx_usage
        return 1
    fi
    shift

    case "$cmd" in
    start|restart)
        local cloud=0 fg=0 root="" ns=""
        while [ $# -gt 0 ]; do
            case "$1" in
            -cloud) cloud=1; shift ;;
            -fg)    fg=1;    shift ;;
            -root|-ns)
                if [ $# -lt 2 ]; then
                    echo "jarx: option $1 requires a value"
                    return 1
                fi
                if [ "$1" = "-root" ]; then root="$2"; else ns="$2"; fi
                shift 2
                ;;
            *)      break ;;
            esac
        done

        local fg_opt=""
        [ $fg -eq 1 ] && fg_opt="-fg"

        # 批量模式：-root / -ns + 一个或多个 jar 文件名
        if [ -n "$root" ] || [ -n "$ns" ]; then
            if [ "$cmd" != "start" ]; then
                echo "jarx: $cmd does not support -root/-ns"
                return 1
            fi
            if [ $cloud -ne 1 ]; then
                echo "jarx: -root/-ns require -cloud"
                return 1
            fi
            _start_project_jars $fg_opt "$root" "$ns" "$@"
            return $?
        fi

        if [ "$cmd" = "restart" ]; then
            if [ $fg -eq 1 ]; then
                echo "jarx: restart does not support -fg"
                return 1
            fi
            if [ -z "$1" ]; then
                _jarx_usage
                return 1
            fi
            # 只给了 JAR：复用正在运行进程的完整启动命令（此时 -cloud 可省略）
            if [ $# -eq 1 ]; then
                _restart_jar_srv "$1"
                return $?
            fi

            # 给了完整参数：按参数重启。先确认 jar 存在，路径写错时不要把正在运行的服务停掉
            if [ ! -f "$1" ]; then
                echo "[$1] jar not found ❌ , 未停止原进程"
                return 1
            fi

            # 未启动时 stop 会返回 1，这里不中断，继续启动
            _stop_jar_srv "$1"
        fi

        if [ $cloud -eq 1 ]; then
            _start_jar_srv_cloud $fg_opt "$@"
        else
            _start_jar_srv $fg_opt "$@"
        fi
        ;;
    stop)
        if [ $# -eq 0 ]; then
            _stop_jar_srv
            return 1
        fi
        local jar rc=0
        for jar in "$@"; do
            _stop_jar_srv "$jar" || rc=1
        done
        return $rc
        ;;
    pids)
        _get_jar_pids "$@"
        ;;
    wait-port)
        _wait_ports "$@"
        ;;
    -h|--help|help)
        _jarx_usage
        ;;
    *)
        echo "jarx: unknown command '$cmd'"
        _jarx_usage
        return 1
        ;;
    esac
}
