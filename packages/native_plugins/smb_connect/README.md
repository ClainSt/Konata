# Konata 的 SMB 客户端副本

此副本基于 `smb_connect 0.0.9`。Konata 仍依赖其中的连接回收、断流处理和取消读流修复。

- 同步传递套接字写入错误。对端关闭、连接建立中断或断开共享失败时，回收传输并通知等待中的请求。
- 处理响应先于等待器到达的情况。收到终止错误时清理等待器，并在明确禁止重试时只发送一次请求。
- 按协商上限读取 SMB2 分块。已发送的数据块持有各自的字节，取消读取时关闭远端句柄。

补丁行为、复现场景和回归用例见 [KONATA_PATCHES.md](KONATA_PATCHES.md)。上游基准见 [pub.dev 发布页](https://pub.dev/packages/smb_connect/versions/0.0.9)。
