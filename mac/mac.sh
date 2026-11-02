source /Users/sharp/nm/p/shell/p/mac/ssrust.sh
source /Users/sharp/nm/p/shell/p/mac/mac_network.sh
source /Users/sharp/nm/p/shell/p/mac/utils.sh
source /usr/local/Cellar/autojump/22.5.3_3/share/autojump/autojump.zsh
source /Users/sharp/nm/p/shell/p/vcs/svn.sh
source /Users/sharp/nm/p/shell/p/android/android.sh
source /Users/sharp/nm/p/shell/p/db/mysql.sh
source /Users/sharp/nm/p/shell/p/db/sqlserver.sh

mac_battery() {
    ioreg -rn AppleSmartBattery | grep -i "MaxCapacity\|Designcapacity"
}

clear_finder_recent() {
    defaults delete com.apple.finder FXRecentFolders
}

clear_finder_cmd_shift_g_recent() {
    defaults delete com.apple.finder GoToField
    defaults delete com.apple.finder GoToFieldHistory
}

clear_dir() {
    rm -fr $1/*;rm -fr $1/.*
}

# ################################## Command #####################################

# 1) 直接执行 mac.sh ssproxyterminal {set|unset|status} 不会起作用，因为方法里涉及到了环境变量，而执行 mac.sh 会开启
#    一个新的子 Shell 进程，对环境变量的操作只会大子 Shell 中生效，不会影响到父 Shell，如果要用 mac.sh 这种方式
#    执行，需要用 source 命令，即：source mac.sh ssproxyterminal {set|unset|status}，但这种方式会使脚本中的所有
#    函数生效，所以还不如直接 source mac.sh 然后在终端中直接调用函数，暂时放弃下面这种方式吧-_-(2025-10-24 20:00:00)

if true; then
    return 0
fi

case "$1" in
    battery)
        mac_battery
        ;;
    network)
        case "$2" in
            all)
                list_all_network
                ;;
            ssproxystatus)
                show_network_socks_proxy_status "$3"
                ;;
            *)
                echo "Usage: $0 $1 {all|ssproxystatus}"
        esac
        ;;
    ssclient)
        case "$2" in
            start)
                start_rust_ss_client
                ;;
            stop)
                stop_rust_ss_client
                ;;
            status)
                show_rust_ss_client_status
                ;;
            *)
                echo "Usage: $0 $1 {start|stop|status}"
        esac
        ;;
    ssproxygui)
        case "$2" in
            set)
                set_gui_network_socks_proxy "$3" "$4" "$5"
                ;;
            unset)
                unset_gui_network_socks_proxy "$3"
                ;;
            *)
                echo "Usage: $0 $1 {set|unset}"
        esac
        ;;
    ssproxyterminal)
        case "$2" in
            set)
                set_terminal_network_socks_proxy "$3" "$4"
                ;;
            unset)
                unset_terminal_network_socks_proxy
                ;;
            status)
                show_terminal_network_socks_proxy_status
                ;;
            *)
                echo "Usage: $0 $1 {set|unset|status}"
        esac
        ;;
    *)
        echo "Usage: $0 {battery|network|ssclient|ssproxygui|ssproxyterminal}"
        exit 1
        ;;
esac
