#!/bin/bash
# 设置你的语言
# set your language (en-US, zh-CN...)
lang="zh-CN"

# 如果需要收集并保存壁纸，请去掉注释并设置保存文件夹路径
# In FileStation, you can right-click the folder and check its properties to find the path.
# 例如：/volume1/myshare/wallpaper
savepath="/volume1/Main/Photos/BingWallpaper"


# 修改用户桌面壁纸，注释掉此行将替换系统的wallpaper1
# 如果你在DSM7.x系统中使用此功能，需要清空浏览器缓存才能看到效果
# Modify user desktop wallpaper. Only test for DSM 7.x.
# System "Wallpaper1" will be replaced if you remove the comment.
# You need to clear the browser cache to see the effect.
desktop=yes

# 输出开始信息
echo "[x] 正在收集信息..."

# 获取Bing壁纸的JSON数据，使用指定的语言（例如：简体中文 zh-CN）
pic="https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1"

# 使用wget下载壁纸数据并解析JSON
pic=$(wget -t 5 --no-check-certificate -qO- $pic --header="cookie:_EDGE_S=mkt=$lang")

# 如果无法获取壁纸信息，退出脚本
echo $pic | grep -q startdate || exit

# 解析返回结果，提取图片的下载链接。
link=$(echo https://www.bing.com$(echo $pic | sed 's/.\+"url"[:" ]\+//g' | sed 's/".\+//g' | sed 's/1920x1080/UHD/g'))

# 获取壁纸的日期（以YYYYMMDD格式）
date=$(echo $pic | grep -Eo '"startdate":"[0-9]+' | grep -Eo '[0-9]+' | head -1)
if [ "$date" == "" ]; then
  # 如果没有找到日期，使用当前日期
  date=$(date +%Y%m%d)
fi

# 提取壁纸标题
title=$(echo $pic | sed 's/.\+"title":"//g' | sed 's/".\+//g')

# 提取壁纸版权信息
copyright=$(echo $pic | sed 's/.\+"copyright[:" ]\+//g' | sed 's/".\+//g')

# 提取关键词（通常为壁纸的第一个关键字）
keyword=$(echo $copyright | sed 's/, /-/g' | cut -d" " -f1 | grep -Eo '[^()\\/:*?"<>]+' | head -1)

# 生成文件名，格式为 bing_YYYYMMDD_keyword.jpg
filename="bing_"$date"_"$keyword".jpg"

# 输出信息
echo "链接: $link"
echo "日期: $date"
echo "标题: $title"
echo "版权: $copyright"
echo "关键词: $keyword"
echo "文件名: $filename"

# 下载壁纸文件
echo "[x] 正在下载壁纸..."
tmpfile=/tmp/$filename
wget -t 5 --no-check-certificate $link -qO $tmpfile

# 检查文件是否成功下载
ls -lah $tmpfile || exit

# 将壁纸复制到指定保存路径
echo "[x] 正在复制壁纸..."
if [ "$savepath" != "" ]; then
  cp $tmpfile "$savepath"
  echo "已保存到: $savepath"
  ls -lah "$savepath" | grep $date
  cd "$savepath"
  chmod 777 $filename  # 设置文件权限为可读写
else
  echo "未设置保存路径，跳过复制."
fi

# 设置系统的登录欢迎信息
echo "[x] 正在设置欢迎信息..."
sed -i s/login_welcome_title=.*//g /etc/synoinfo.conf
echo "login_welcome_title=\"$title\"" >> /etc/synoinfo.conf
sed -i s/login_welcome_msg=.*//g /etc/synoinfo.conf
echo "login_welcome_msg=\"$copyright\"" >> /etc/synoinfo.conf

# 应用登录页面壁纸
echo "[x] 正在应用登录页面壁纸..."
sed -i s/login_background_customize=.*//g /etc/synoinfo.conf
echo "login_background_customize=\"yes\"" >> /etc/synoinfo.conf
sed -i s/login_background_type=.*//g /etc/synoinfo.conf
echo "login_background_type=\"fromDS\"" >> /etc/synoinfo.conf

# 删除现有的登录背景文件，并使用新下载的壁纸替换
rm -rf /usr/syno/etc/login_background*.jpg
cp -f $tmpfile /usr/syno/etc/login_background.jpg
ln -sf /usr/syno/etc/login_background.jpg /usr/syno/etc/login_background_hd.jpg

# 清理临时文件
echo "[x] 清理临时文件..."
rm -f /tmp/bing_*.jpg

# 如果 desktop 参数设置为 "yes"，则应用为用户桌面壁纸
if [ "$desktop" == "yes" ]; then
  echo "[x] 正在应用用户桌面壁纸..."
  mkdir -p /usr/syno/synoman/webman/resources/images/2x/default_wallpaper/
  mkdir -p /usr/syno/synoman/webman/resources/images/1x/default_wallpaper/
  mkdir -p /usr/syno/synoman/webman/resources/images/default/1x/default_wallpaper/
  mkdir -p /usr/syno/synoman/webman/resources/images/default_wallpaper/

  # DSM 7.x
  cp -f /usr/syno/etc/login_background.jpg /usr/syno/synoman/webman/resources/images/2x/default_wallpaper/dsm7_01.jpg
  ln -sf /usr/syno/synoman/webman/resources/images/2x/default_wallpaper/dsm7_01.jpg /usr/syno/synoman/webman/resources/images/1x/default_wallpaper/dsm7_01.jpg

  # DSM 6.x 和更早版本
  ln -sf /usr/syno/synoman/webman/resources/images/2x/default_wallpaper/dsm7_01.jpg /usr/syno/synoman/webman/resources/images/default/1x/default_wallpaper/default_wallpaper.jpg
  ln -sf /usr/syno/synoman/webman/resources/images/2x/default_wallpaper/dsm7_01.jpg /usr/syno/synoman/webman/resources/images/default/1x/default_wallpaper/dsm6_01.jpg
  ln -sf /usr/syno/synoman/webman/resources/images/2x/default_wallpaper/dsm7_01.jpg /usr/syno/synoman/webman/resources/images/default/1x/default_wallpaper/dsm6_02.jpg
  ln -sf /usr/syno/synoman/webman/resources/images/2x/default_wallpaper/dsm7_01.jpg /usr/syno/synoman/webman/resources/images/default_wallpaper/default_wallpaper.jpg
  ln -sf /usr/syno/synoman/webman/resources/images/2x/default_wallpaper/dsm7_01.jpg /usr/syno/synoman/webman/resources/images/default_wallpaper/01.jpg
  ln -sf /usr/syno/synoman/webman/resources/images/2x/default_wallpaper/dsm7_01.jpg /usr/syno/synoman/webman/resources/images/default_wallpaper/02.jpg
fi