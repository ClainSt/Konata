# engine_cloud_drives

纯 Dart 只读云盘引擎，仅依赖 konata_contracts 与 crypto。公开出口 engine_cloud_drives.dart。

GuangYaProtocol 隔离鉴权与目录、取链协议；LegacyGuangYaProtocol 实验性既有接口适配，使用用户有权使用的应用凭据，禁止预置他方身份或签名。GuangYaGateway 复用统一媒体源及范围读取契约。未使用时不创建连接；真实接口兼容性以授权测试为准。
GuangYaCredentialStore 通过 SecureStoragePort 隔离本机账号凭据，串行化同账号读写与删除，并比较旧授权后轮换令牌，拒绝过期会话覆写。宿主应共享单一仓储实例；宿主共享单一实例。

GuangYaSessionRegistry 提供云盘驱动注册贡献、同账号协议会话共享及独立网关释放，重新授权和注销关闭旧会话；不启动后台服务或常驻定时器。宿主装配已接入，实际账号授权仍需验收。

GuangYaAccountSignIn 通过 CloudAccountSignInPort 接入用户主动授权交互，按服务端主体生成稳定绑定标识；默认不配置客户端身份，真实登录需获准使用的应用配置。
