#!/bin/bash
# 设置你的语言
# 设置用于Bing API的语言，如中文("zh-CN")或英语("en-US")。
lang="zh-CN"

# 如需收集保存壁纸,请去掉下面注释,设置保存文件夹路径
# 在FileStation里面右键文件夹属性可以看到路径
# 定义保存路径，如果用户希望收集并保存下载的壁纸。
savepath="/vol1/1000/Images/BingWallpaper"

# 设置FNOS壁纸路径变量
wallpaper_path="/usr/trim/var/trim_sac/wallpaper/1000/204b94e3-62b9-4a36-aad3-7942a00c16fa.jpg"

# 设置缓存壁纸路径变量
thumb_wallpaper_path="/usr/trim/var/trim_sac/wallpaper/1000/thumb-204b94e3-62b9-4a36-aad3-7942a00c16fa.jpg"

# 提示正在收集信息
echo "[x] 正在收集信息..."

# 定义Bing API的请求链接，获取最新一张图片的信息。
pic="https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1"

# 使用wget获取API的JSON响应，设置语言参数。
pic=$(wget -t 5 --no-check-certificate -qO- $pic --header="cookie:_EDGE_S=mkt=$lang")

# 检查返回结果中是否包含startdate关键字，确保请求成功。
echo $pic | grep -q startdate || exit

# 解析返回结果，提取图片的下载链接。
thumb_link=$(echo https://www.bing.com$(echo $pic | sed 's/.\+"url"[:" ]\+//g' | sed 's/".\+//g'))
link=$(echo $thumb_link | sed 's/1920x1080/UHD/g')

# 提取图片的发布日期，如果没有获取到则使用当前日期
date=$(echo $pic | grep -Eo '"startdate":"[0-9]+' | grep -Eo '[0-9]+' | head -1)
date=${date:-$(date +%Y%m%d)}

# 提取图片的标题
title=$(echo $pic | sed 's/.\+"title":"//g' | sed 's/".\+//g')

# 提取图片的版权信息
copyright=$(echo $pic | sed 's/.\+"copyright[:" ]\+//g' | sed 's/".\+//g')

# 提取关键词，用于生成文件名
keyword=$(echo $copyright | sed 's/, /-/g' | cut -d" " -f1 | grep -Eo '[^()\\/:*?"<>]+' | head -1)

# 构建JPG文件的文件名
filename="bing_"$date"_"$keyword".jpg"

# 输出获取到的关键信息
echo "PIC: $pic"
echo "链接: $link"
echo "缩略图链接: $thumb_link"
echo "发布日期: $date"
echo "标题: $title"
echo "版权信息: $copyright"
echo "关键词: $keyword"
echo "文件名: $filename"

# 提示正在下载壁纸
echo "[x] 正在下载壁纸..."

# 定义临时文件路径并下载图片
tmpfile=/tmp/$filename
thumb_tmpfile=/tmp/thumb-$filename
wget -t 5 --no-check-certificate $link -qO $tmpfile
wget -t 5 --no-check-certificate $thumb_link -qO $thumb_tmpfile

# 检查下载是否成功
if [[ ! -f $tmpfile || ! -f $thumb_tmpfile ]]; then
    echo "[x] 下载失败！"
    exit 1
fi

# 保存高清壁纸到指定的路径
if [ "$savepath" != "" ]; then
    echo "[x] 正在保存高清壁纸到保存路径..."
    mkdir -p "$savepath"
    cp $tmpfile "$savepath/$filename"
    chmod 755 "$savepath/$filename"
fi

# 提示正在将图片复制到FNOS路径
echo "[x] 正在复制JPG壁纸到FNOS路径..."

# 使用 wallpaper_path 变量复制高清壁纸
sudo cp -f /tmp/$filename "$wallpaper_path"
sudo cp -f $thumb_tmpfile "$thumb_wallpaper_path"

# 提示正在清理临时文件
echo "[x] 清理临时文件..."

# 删除下载的临时文件
sudo rm -f /tmp/bing_*.jpg
sudo rm -f /tmp/thumb-bing_*.jpg

# 提示操作完成
echo "[x] 完成！你的壁纸已更新。"