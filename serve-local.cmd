@echo off
chcp 65001 >nul
cd /d "%~dp0install"
echo 安装器地址：http://127.0.0.1:8000/multi_install.lua
echo 下载期间请保持窗口开启。按 Ctrl+C 停止服务。
python -m http.server 8000 --bind 127.0.0.1
pause
