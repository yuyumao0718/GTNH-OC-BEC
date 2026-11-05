# 成熟版算法对照

本目录的 Lua 文件提取自用户提供的 `cache_install.lua`，仅清理行尾空白和换行，作为独立、固定的测试基准，不随运行代码改写，也不打包到 OC 安装器。

`bec_nanites.lua` 对照阶段定位、参考节点、等级选择与 fastTier；`bec_intake.lua` 对照物品身份、样板签名和配方份数。完整单台控制器的执行对照使用 `simulation/user_cache_compare.py` 从原安装器解出的程序。
