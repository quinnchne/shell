compr() {
    if [ ${1} = ${2} ]
    then # 必须换行，不换行需要在 if 条件后加 ; 号
        echo "true"
    else
        echo "false"
    fi
}

upper() {
    echo ${1} | tr '[:lower:]' '[:upper:]'
}

lower() {
    echo ${1} | tr '[:upper:]' '[:lower:]'
}

len() {
    echo ${#1} 
}

lessx() {
    # 逐个用 less 打开文件，查看完后输出该文件的完整路径
    find "$2" -name "$1" -exec sh -c '
        for file do
            less "$file"
            printf "%s\n" "$(cd "$(dirname "$file")" && pwd -P)/$(basename "$file")"
        done
    ' sh {} +
}

grepx() {
    grep -lr $1 $2
}
