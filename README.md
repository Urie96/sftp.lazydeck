# sftp.lazycmd

基于 `file` 浏览器框架的远程文件系统插件。

当前实现通过本机 `ssh` 命令在远端执行文件操作，不依赖额外 Rust API。

## 功能

- `/sftp` 展示已配置的 profile 列表
- `/sftp/<profile>` 进入对应远端目录浏览
- 复用 `file` 插件的目录列表、文本预览、隐藏文件切换、选中/复制/剪切/删除/新建/重命名逻辑
- 文件页支持用本地编辑器编辑远端文件，保存后自动通过 `scp` 写回原路径
- 每个 profile 都持有独立 browser 实例，互不共享选中态和剪贴板态

## 配置

```lua
{
  dir = 'plugins/sftp.lazycmd',
  config = function()
    require('sftp').setup {
      profiles = {
        prod = {
          host = 'example.com',
          user = 'deploy',
          port = 22,
          base_dir = '/var/www',
          ssh_opts = { '-o', 'BatchMode=yes' },
        },
      },
    }
  end,
},
```

## 限制

- 当前依赖远端存在 `sh`、`find`、`head`、`cp`、`mv`、`rm`、`mkdir`
- 路径名里包含制表符或换行时，列表解析不可靠
- 这是第一版实现，底层传输走 `ssh` 远端命令，不是原生 SFTP 客户端协议封装
