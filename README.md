# BEC 公共原料子网简化版

单台 OpenComputers 控制多台观测阵列，共用原料子网和蜂群池；支持纠缠流体预缓存、fastTier、算力奇点收集与中断续做。

- [安装、接线、配置与使用说明](使用说明.md)
- [带实际界面渲染的配置示例](wiki/index.html)
- [测试方法与覆盖范围](测试说明.md)
- [49 套与 54 套共享蜂群的星门耗时](simulation/49套与54套蜂群.md)

游戏内安装器：[`install/multi_install.lua`](install/multi_install.lua)。安装器内含程序文件，保留已有配置和配方缓存，运行时从节点及公共 AE 子网续做。
