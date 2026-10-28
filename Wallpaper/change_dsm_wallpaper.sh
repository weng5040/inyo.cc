#!/bin/bash
# 设置你的语言
# set your language (en-US, zh-CN...)
lang="zh-CN"

# 如果需要收集并保存壁纸，请去掉注释并设置保存文件夹路径
# In FileStation, you can right-click the folder and check its properties to find the path.
# 例如：/volume1/Photo/BingWallpaper
savepath="/volume1/Image/BingWallpaper"


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

# 设置系统的登录欢迎信息 + 应用登录页面壁纸
# 采用「生成副本 -> 校验 -> 原子替换(rename)」方式写入 /etc/synoinfo.conf：
#   1) 只在副本上改动，原文件全程不动
#   2) 校验通过才用 mv(rename) 原子换入，失败则丢弃副本、原文件零改动
#   3) 旧键用 grep -v 真正删除（不再用 sed 清空行），文件不会随运行次数膨胀
echo "[x] 正在更新 synoinfo.conf（原子写入）..."
SYNOINFO=/etc/synoinfo.conf
SYNOINFO_NEW="${SYNOINFO}.new.$$"
SYNOINFO_OK=0

# 转义双引号与反斜杠，避免标题/版权含特殊字符时把配置写坏
esc_q() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# 备份当前配置（优先放到壁纸保存目录，未设置则放 /root）
if [ -n "$savepath" ] && [ -d "$savepath" ]; then
  SYNOINFO_BAK="$savepath/synoinfo.conf.bak.$(/bin/date +%Y%m%d)"
elif [ -d /root ]; then
  SYNOINFO_BAK="/root/synoinfo.conf.bak.$(/bin/date +%Y%m%d)"
else
  SYNOINFO_BAK=""
fi
if [ -n "$SYNOINFO_BAK" ]; then
  cp -p "$SYNOINFO" "$SYNOINFO_BAK" 2>/dev/null && echo "已备份配置: $SYNOINFO_BAK"
fi

# 以原文件为底稿生成副本（临时文件必须与目标同分区，rename 才是原子的）
if grep -v -E '^login_(welcome_title|welcome_msg|background_customize|background_type)=' "$SYNOINFO" > "$SYNOINFO_NEW" 2>/dev/null; then
  {
    printf 'login_welcome_title="%s"\n' "$(esc_q "$title")"
    printf 'login_welcome_msg="%s"\n' "$(esc_q "$copyright")"
    printf 'login_background_customize="yes"\n'
    printf 'login_background_type="fromDS"\n'
  } >> "$SYNOINFO_NEW"

  # 校验：文件非空、4 个键各恰好 1 条、体积合理
  [ -s "$SYNOINFO_NEW" ] || SYNOINFO_OK=-1
  for k in login_welcome_title login_welcome_msg login_background_customize login_background_type; do
    [ "$(grep -c "^${k}=" "$SYNOINFO_NEW")" -eq 1 ] || SYNOINFO_OK=-1
  done
  [ "$(wc -c < "$SYNOINFO_NEW")" -gt 5000 ] || SYNOINFO_OK=-1

  # 属主与权限必须在替换前设好（mv 生效的是副本自身的属性）
  if [ "$SYNOINFO_OK" != "-1" ]; then
    if chown root:root "$SYNOINFO_NEW" 2>/dev/null && chmod 644 "$SYNOINFO_NEW" 2>/dev/null; then
      SYNOINFO_OK=1
    fi
  fi

  if [ "$SYNOINFO_OK" = "1" ]; then
    sync
    if mv -f "$SYNOINFO_NEW" "$SYNOINFO"; then
      sync
      echo "[x] synoinfo.conf 已原子更新"
    else
      echo "[!] 替换失败，原配置未改动"
      rm -f "$SYNOINFO_NEW"
      SYNOINFO_OK=0
    fi
  else
    echo "[!] 新配置校验未通过，已放弃写入，原配置未改动"
    rm -f "$SYNOINFO_NEW"
    SYNOINFO_OK=0
  fi
else
  echo "[!] 生成新配置失败，原配置未改动"
  rm -f "$SYNOINFO_NEW"
  SYNOINFO_OK=0
fi

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
  #ln -sf /usr/syno/synoman/webman/resources/images/2x/default_wallpaper/dsm7_01.jpg /usr/syno/synoman/webman/resources/images/default/1x/default_wallpaper/default_wallpaper.jpg
  #ln -sf /usr/syno/synoman/webman/resources/images/2x/default_wallpaper/dsm7_01.jpg /usr/syno/synoman/webman/resources/images/default/1x/default_wallpaper/dsm6_01.jpg
  #ln -sf /usr/syno/synoman/webman/resources/images/2x/default_wallpaper/dsm7_01.jpg /usr/syno/synoman/webman/resources/images/default/1x/default_wallpaper/dsm6_02.jpg
  #ln -sf /usr/syno/synoman/webman/resources/images/2x/default_wallpaper/dsm7_01.jpg /usr/syno/synoman/webman/resources/images/default_wallpaper/default_wallpaper.jpg
  #ln -sf /usr/syno/synoman/webman/resources/images/2x/default_wallpaper/dsm7_01.jpg /usr/syno/synoman/webman/resources/images/default_wallpaper/01.jpg
  #ln -sf /usr/syno/synoman/webman/resources/images/2x/default_wallpaper/dsm7_01.jpg /usr/syno/synoman/webman/resources/images/default_wallpaper/02.jpg
fi

# 若 synoinfo.conf 写入失败，返回非零，便于任务计划记录到异常
[ "$SYNOINFO_OK" = "1" ] || exit 1
