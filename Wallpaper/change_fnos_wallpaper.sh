#!/bin/bash
# 设置你的语言
# 设置用于Bing API的语言，如中文("zh-CN")或英语("en-US")。
lang="zh-CN"

# 如需收集保存壁纸,请去掉下面注释,设置保存文件夹路径
# 在FileStation里面右键文件夹属性可以看到路径
# 定义保存路径，如果用户希望收集并保存下载的壁纸。
#savepath="/volume1/Photo/BingWallpaper"

# 如需下载4k分辨率,请设置res=4k
# 如需下载体积更大的4k以上分辨率的原始图片,请设置res=raw
# 选择图片的分辨率，可以设置为4K或原始分辨率。
res=raw

# 提示正在收集信息
echo "[x]Collecting information..."

# 定义Bing API的请求链接，获取最新一张图片的信息。
pic="https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1"

# 如果选择的分辨率不为空，更新链接以获取4K或更高分辨率的图片。
if [ "$res" != "" ]
then
    pic="https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&uhd=1&uhdwidth=3840&uhdheight=2160"
fi

# 使用wget获取API的JSON响应，设置语言参数。
pic=$(wget -t 5 --no-check-certificate -qO- $pic --header="cookie:_EDGE_S=mkt=$lang")

# 检查返回结果中是否包含startdate关键字，确保请求成功。
echo $pic | grep -q startdate || exit

# 解析返回结果，提取图片的下载链接。
link=$(echo https://www.bing.com$(echo $pic | sed 's/.\+"url"[:" ]\+//g' | sed 's/".\+//g'))

# 如果选择的是原始分辨率，则从解析结果中提取完整的链接。
if [ "$res" == "raw" ]
then
    link=$(echo $link | grep -Eo "https://[-=?/._a-zA-Z0-9]+")
fi

# 提取图片的发布日期
date=$(echo $pic | grep -Eo '"startdate":"[0-9]+' | grep -Eo '[0-9]+' | head -1)

# 如果没有获取到发布日期，则使用当前日期
if [ "$date" == "" ]
then
    date=$(date +%Y%m%d)
fi

# 提取图片的标题
title=$(echo $pic | sed 's/.\+"title":"//g' | sed 's/".\+//g')

# 提取图片的版权信息
copyright=$(echo $pic | sed 's/.\+"copyright[:" ]\+//g' | sed 's/".\+//g')

# 提取关键词，用于生成文件名
keyword=$(echo $copyright | sed 's/, /-/g' | cut -d" " -f1 | grep -Eo '[^()\\/:*?"<>]+' | head -1)

# 构建JPG和WebP文件的文件名
filename="bing_"$date"_"$keyword".jpg"
webpfile="bing_"$date"_"$keyword".webp"

# 输出获取到的关键信息
echo "Link:"$link
echo "Date:"$date
echo "Title:"$title
echo "Copyright:"$copyright
echo "Keyword:"$keyword
echo "Filename:"$filename
echo "Webp Filename:"$webpfile

# 提示正在下载壁纸
echo "[x]Downloading wallpaper..."

# 定义临时文件路径并下载图片
tmpfile=/tmp/$filename
wget -t 5 --no-check-certificate $link -qO $tmpfile

# 检查下载是否成功
ls -lah $tmpfile || exit

# 提示正在将JPG转换为WebP格式
echo "[x]Converting JPG to WebP..."

# 使用ImageMagick的convert命令将JPG格式的壁纸转换为WebP格式
convert $tmpfile /tmp/$webpfile

# 提示正在将WebP格式的壁纸复制到fnos路径
echo "[x]Copying WebP wallpaper to fnos path..."

# 将转换后的WebP文件复制到指定路径
cp -f /tmp/$webpfile /usr/trim/www/static/thumbnail_bg/wallpaper-1.webp

# 更改新壁纸的权限为可读写
chmod 777 /usr/trim/www/static/thumbnail_bg/wallpaper-1.webp

# 提示正在清理临时文件
echo "[x]Clean..."

# 删除下载的临时文件
rm -f /tmp/bing_*.jpg /tmp/bing_*.webp

# 提示操作完成
echo "[x]Done. Your wallpaper is updated."