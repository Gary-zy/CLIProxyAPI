# CLIProxyAPI 本地部署与脚本使用教程

这份文档是给“第一次拿到这个仓库的人”准备的。

目标很直接：

- 不手改仓库里的 `docker-compose.yml`
- 不把本地配置、认证文件、日志塞回仓库目录
- 用一个脚本完成初始化、启动、重启、更新
- 以后仓库代码更新时，尽量不跟本地运行数据打架

当前统一入口脚本：

```bash
./scripts/cliproxy-local.sh
```

## 1. 适用场景

这套方案适合下面几种情况：

- 你要在本机长期运行 CLIProxyAPI
- 你想把“代码”和“本地配置”分开管理
- 你后面还会经常 `git pull` 更新仓库
- 你不想每次更新都重新导认证文件

## 2. 运行前提

使用前请确保机器上已经安装：

- Git
- Docker
- Docker Compose
- Bash
- Python 3

推荐环境：

- macOS
- Linux

Windows 用户如果要用，建议走 WSL 或 Git Bash。别硬拿 CMD / PowerShell 生怼，不然路径和换行容易整出幺蛾子。

## 3. 仓库目录与本地数据目录

### 3.1 仓库目录

假设仓库放在：

```bash
/Users/zhangyang/Code/github/cliProxyApi/CLIProxyAPI
```

脚本位置：

[`scripts/cliproxy-local.sh`](/Users/zhangyang/Code/github/cliProxyApi/CLIProxyAPI/scripts/cliproxy-local.sh)

### 3.2 本地数据目录

脚本默认不会把运行数据写回仓库，而是写到：

```bash
~/.config/cliproxyapi-local
```

也就是：

- 配置文件：`~/.config/cliproxyapi-local/config.yaml`
- 认证目录：`~/.config/cliproxyapi-local/auths`
- 日志目录：`~/.config/cliproxyapi-local/logs`
- 本地 override 文件：`~/.config/cliproxyapi-local/docker-compose.local.yml`
- 运行态环境文件：`~/.config/cliproxyapi-local/runtime.env`

这样做的好处很直接：

- 仓库更新时，不容易和你的本地配置冲突
- 删除仓库不会顺手把认证文件删了
- 迁移到别的目录时更方便

## 4. 第一次使用

### 4.1 克隆仓库

```bash
git clone https://github.com/router-for-me/CLIProxyAPI.git
cd CLIProxyAPI
```

如果你已经有仓库，就直接进入仓库根目录：

```bash
cd /你的仓库路径/CLIProxyAPI
```

### 4.2 源码模式直接启动

第一次使用时，最简单的命令就是：

```bash
./scripts/cliproxy-local.sh start
```

脚本会自动做这些事：

1. 检查 Docker 是否可用
2. 如果是 macOS 且 Docker Desktop 没启动，尝试自动拉起
3. 创建本地数据目录
4. 初始化 `config.yaml`
5. 生成本地 `docker-compose.local.yml`
6. 如果当前是源码模式，先检查 `upstream/main`
7. 用源码 build 并启动容器

### 4.3 release 包直装模式

如果你只是想稳定部署，不想每次都去合上游代码再本地打包，那就直接走 release 包模式。

对当前这台机器来说：

- 你在 macOS `arm64` 上跑 Docker
- Docker 里实际跑的是 Linux 容器
- 所以应该下载的不是 `darwin_arm64`，而是：

```bash
CLIProxyAPI_<版本>_linux_arm64.tar.gz
```

推荐流程：

1. 去 release 页面下载对应版本的 `CLIProxyAPI_<版本>_linux_arm64.tar.gz`
2. 把包放到：

```bash
~/.config/cliproxyapi-local/packages
```

3. 然后执行：

```bash
./scripts/cliproxy-local.sh deploy-package
```

如果包不在默认目录，也可以直接带路径：

```bash
./scripts/cliproxy-local.sh deploy-package /你的路径/CLIProxyAPI_<版本>_linux_arm64.tar.gz
```

脚本会自动做这些事：

1. 解压 release 包
2. 用包里的二进制生成本地 Docker 镜像
3. 切换到 `release 包模式`
4. 重新部署服务

以后你再执行：

```bash
./scripts/cliproxy-local.sh start
```

它会继续按当前模式启动；如果你上次部署的是 release 包，它就不会去碰 Git 上游同步。

### 4.4 初始化时配置文件从哪里来

脚本初始化配置时，优先级如下：

1. `~/.cli-proxy-api/config.yaml`
2. 仓库里的 `config.yaml`
3. 仓库里的 `config.example.yaml`

也就是说：

- 如果你以前用过旧版 CLIProxyAPI，脚本会优先复用旧配置
- 如果没有旧配置，它会从示例配置生成一份新的

### 4.5 第一次启动后的访问地址

默认访问地址：

- 管理面板：`http://127.0.0.1:8317/management.html`
- API 根地址：`http://127.0.0.1:8317`

### 4.6 默认管理密码

如果你是全新初始化，且没有提供自定义管理密码，脚本默认使用：

```bash
Niubao123
```

这个值只是在“第一次初始化时”写进你的本地配置文件，不是仓库写死的神秘默认值。

只有在下面这些条件同时满足时，默认值才会生效：

- 当前机器上不存在旧的 `~/.cli-proxy-api/config.yaml`
- 当前机器上不存在新的 `~/.config/cliproxyapi-local/config.yaml`
- 启动前没有设置 `CLIPROXY_MANAGEMENT_KEY`

真正生效的是：

```bash
~/.config/cliproxyapi-local/config.yaml
```

建议首次启动后尽快改掉。

如果你希望第一次启动时就指定自己的管理密码，可以直接这样执行：

```bash
CLIPROXY_MANAGEMENT_KEY='你的强密码' ./scripts/cliproxy-local.sh start
```

如果配置文件已经存在，脚本会保留已有密码，不会每次启动都重新改写。

## 5. 常用命令

所有命令都需要在仓库根目录执行。

### 5.1 启动或重建服务

```bash
./scripts/cliproxy-local.sh start
```

适合：

- 第一次启动
- 改完配置后重新拉起
- 日常启动

`start` 现在是“按当前部署模式启动”：

- 如果当前是源码模式，它会先做一轮 Git 检查
- 如果当前是 release 包模式，它会直接启动当前已安装的 release 镜像

源码模式下，`start` 会：

1. 检查 `origin` 和 `upstream` remote 是否正确
2. 当前分支如果是 `main`，先 `fetch upstream`
3. 如果 `upstream/main` 有更新，先同步代码
4. 只有代码真的变了，才触发镜像重建

### 5.2 查看状态

```bash
./scripts/cliproxy-local.sh status
```

会输出：

- 容器状态
- 本地配置路径
- 本地认证目录
- 本地日志目录
- 当前部署模式
- 当前 release 包路径 / 版本 / 镜像
- 推荐下载的 release 包名
- 当前分支
- `origin` / `upstream` 地址
- 相对 `upstream/main` 的 ahead / behind 状态
- 管理面板地址

### 5.3 查看日志

```bash
./scripts/cliproxy-local.sh logs
```

### 5.4 停止服务

```bash
./scripts/cliproxy-local.sh stop
```

### 5.5 重启服务

```bash
./scripts/cliproxy-local.sh restart
```

### 5.6 仅初始化本地目录和配置

```bash
./scripts/cliproxy-local.sh init
```

适合：

- 先生成配置文件，再慢慢改
- 只想看本地运行目录落在哪里

### 5.7 同步上游并强制重建源码服务

```bash
./scripts/cliproxy-local.sh update
```

这条命令现在是“源码模式专用重活”：

1. 检查仓库工作区是否干净
2. `git fetch upstream`
3. 同步 `upstream/main`
4. 不管代码有没有变化，都强制重建镜像并启动

如果你当前在 release 包模式，执行 `update` 时，脚本会切回源码模式。

### 5.8 直接重建当前本地源码

```bash
./scripts/cliproxy-local.sh rebuild
```

适合：

- 你自己刚改完本地源码
- 不想拉上游，只想重新打包部署

这条命令不会碰 Git 同步，只会强制本地重建并重新部署。

### 5.9 用本地 release 包重新部署

```bash
./scripts/cliproxy-local.sh deploy-package
```

适合：

- 你不想自己合上游代码
- 你只想下载官方 release 包然后更新

如果默认目录里有多个包，脚本会挑最新那个匹配当前架构的包。

## 6. Fork 工作流

如果你准备长期维护自己的版本，推荐使用 fork，而不是直接在上游仓库里瞎改。

推荐 remote 结构：

- `origin` 指向你自己的 fork
- `upstream` 指向原仓库

例如：

```bash
origin   = https://github.com/Gary-zy/CLIProxyAPI.git
upstream = https://github.com/router-for-me/CLIProxyAPI.git
```

### 6.1 首次切换到 fork

如果你当前本地仓库还指着上游，可以执行：

```bash
git remote set-url origin https://github.com/Gary-zy/CLIProxyAPI.git
git remote add upstream https://github.com/router-for-me/CLIProxyAPI.git
```

如果 `upstream` 已存在，就不用重复添加。

### 6.2 推荐日常工作流

```bash
./scripts/cliproxy-local.sh start
```

脚本会在启动前自动检查 `upstream/main` 是否有更新。

如果你想显式做一次同步，再启动：

```bash
./scripts/cliproxy-local.sh update
```

### 6.3 脏仓库策略

如果仓库里还有未提交的 tracked 改动，脚本不会自动同步上游。

它会直接提示你先处理：

- `git status`
- 提交改动
- 或者自己决定怎么清理

脚本不会帮你自动 stash，也不会帮你强制覆盖。

## 7. 如何给朋友使用

如果你要把这套东西给朋友，最简单的说法就是：

### 6.1 朋友第一次使用流程

1. 安装 Git、Docker、Python 3
2. 克隆仓库
3. 进入仓库根目录
4. 执行：

```bash
./scripts/cliproxy-local.sh start
```

5. 浏览器打开：

```bash
http://127.0.0.1:8317/management.html
```

6. 用管理密码登录
7. 再去面板里导入认证文件，或者重新登录 OAuth

### 6.2 如果朋友有旧的 CLIProxyAPI 运行数据

如果朋友机器上已经有旧目录：

```bash
~/.cli-proxy-api
```

脚本会自动尝试迁移：

- 旧配置文件
- 旧认证文件
- 旧日志文件

前提是新目录的 `auths` 还是空的。

所以对老用户来说，通常不需要重新导一遍认证文件。

### 6.3 如果朋友是全新用户

全新用户默认没有认证文件，这很正常。

这时有两种做法：

- 在管理面板中通过 OAuth 登录
- 在管理面板中导入已有的认证文件

## 8. 认证文件会不会丢

正常不会。

原因很简单：

- 认证文件已经不放在仓库里了
- 认证目录固定在 `~/.config/cliproxyapi-local/auths`
- 更新仓库代码不会删这个目录
- 重建 Docker 容器也不会删这个目录

当前脚本还带了一个迁移逻辑：

- 如果发现旧目录 `~/.cli-proxy-api` 存在
- 且新目录 `auths` 还是空的
- 就会自动把旧认证文件拷过来

## 9. 统计信息会不会保留

这里要单独说清楚。

### 8.1 认证文件和统计信息不是一回事

- 认证文件是落盘文件，可以迁移和保留
- 使用统计只有在 `usage-statistics-enabled: true` 时才会记录
- 开启后会自动落盘到 `config.yaml` 同目录下的 `usage-statistics.json`

所以：

- 服务不重启时，统计会继续累积
- 服务重启后，会自动从 `usage-statistics.json` 恢复

### 8.2 如果你想迁移统计到别的环境

更新前先导出：

```bash
curl -sS \
  -H 'X-Management-Key: 你的管理密码' \
  http://127.0.0.1:8317/v0/management/usage/export \
  -o ~/.config/cliproxyapi-local/usage-export.json
```

更新后再导回去：

```bash
curl -sS -X POST \
  -H 'X-Management-Key: 你的管理密码' \
  -H 'Content-Type: application/json' \
  --data @~/.config/cliproxyapi-local/usage-export.json \
  http://127.0.0.1:8317/v0/management/usage/import
```

如果只是本机重启，一般不用手动导出导入。

## 10. 修改管理密码

打开本地配置文件：

```bash
~/.config/cliproxyapi-local/config.yaml
```

找到：

```yaml
remote-management:
  allow-remote: true
  secret-key: "Niubao123"
```

把 `secret-key` 改成你自己的密码，然后执行：

```bash
./scripts/cliproxy-local.sh restart
```

## 11. 自定义本地数据目录

如果你不想用默认目录 `~/.config/cliproxyapi-local`，可以在执行脚本前设置环境变量：

```bash
CLIPROXY_LOCAL_HOME=/你的目录 ./scripts/cliproxy-local.sh start
```

比如：

```bash
CLIPROXY_LOCAL_HOME=$HOME/cliproxy-data ./scripts/cliproxy-local.sh start
```

## 12. 自定义默认管理密码

如果你想在第一次初始化时就指定自己的管理密码，可以这样：

```bash
CLIPROXY_MANAGEMENT_KEY='你的强密码' ./scripts/cliproxy-local.sh start
```

注意：

- 这个变量主要影响“初始化时写入配置”的默认值
- 如果本地 `config.yaml` 已经存在，脚本会保留已存在的密码

## 13. 自定义端口

如果本机端口冲突，可以在启动时指定端口：

```bash
CLIPROXY_PORT_8317=9317 ./scripts/cliproxy-local.sh start
```

支持的端口变量有：

- `CLIPROXY_PORT_8317`
- `CLIPROXY_PORT_8085`
- `CLIPROXY_PORT_1455`
- `CLIPROXY_PORT_54545`
- `CLIPROXY_PORT_51121`
- `CLIPROXY_PORT_11451`

如果你希望局域网访问，而不是只监听 `127.0.0.1`，可以指定绑定地址：

```bash
CLIPROXY_BIND_IP=0.0.0.0 ./scripts/cliproxy-local.sh start
```

脚本会把这个绑定地址写进 `runtime.env`，后续 `start / restart / update / rebuild / deploy-package` 会继续沿用。

例如同时改多个端口：

```bash
CLIPROXY_PORT_8317=9317 \
CLIPROXY_PORT_1455=2455 \
./scripts/cliproxy-local.sh start
```

改完后，管理面板地址也会跟着变，比如：

```bash
http://127.0.0.1:9317/management.html
```

## 14. 到底该走 release 包还是源码更新

这俩方案各有适用场景，但如果你问“哪个更省心”，结论其实挺明确：

- 如果你主要是自己用，想稳定、少折腾，优先走 `release 包直装`
- 如果你自己还要改代码，或者要跟 fork 工作流混着维护，就继续走 `源码更新`

### 14.1 更推荐的方案：release 包直装

优点：

- 不用先合并上游代码
- 不用在本地重新编译 Go 项目
- 更新动作更单纯，出问题也更好定位
- 你的仓库可以继续留给“改代码”这件事，不跟“部署运行”搅一块

推荐命令：

```bash
./scripts/cliproxy-local.sh deploy-package
```

你只需要提前把 release 包放到：

```bash
~/.config/cliproxyapi-local/packages
```

### 14.2 什么时候继续用源码更新

下面这些情况，还是源码模式更合适：

- 你本地有自己改过的代码
- 你需要跟 `origin/upstream` fork 流程一起维护
- 你想验证自己分支上的变更

对应命令：

```bash
./scripts/cliproxy-local.sh update
```

不要自己手工混着搞：

- 一会儿 `git pull`
- 一会儿直接 `docker compose up`
- 一会儿又改仓库里的 `docker-compose.yml`

这种最容易把现场搞乱。

### 14.3 update 做了什么

`update` 会：

1. 检查仓库里是否还有未提交的已跟踪修改
2. 拉取最新代码
3. 强制重新 build 并启动服务

### 14.4 rebuild 是干啥的

```bash
./scripts/cliproxy-local.sh rebuild
```

这条命令不拉上游。

它就是拿你当前本地仓库里的代码，直接重新 build 然后重新部署。

### 14.5 update 为什么会检查仓库是否干净

因为如果你手改了仓库里的 tracked 文件，再 `git pull`，最容易冲突。

脚本这一步是故意拦你，不是它脾气大，是防止你把自己坑了。

如果看到类似提示：

```bash
仓库里还有已跟踪文件改动，先处理掉再 update，别硬拽。
```

说明你应该先处理这些改动。

## 15. 常见问题

### 14.1 为什么访问根路径只看到 JSON

因为：

```bash
http://127.0.0.1:8317/
```

是 API 根路径，不是管理面板。

管理面板地址是：

```bash
http://127.0.0.1:8317/management.html
```

### 14.2 为什么之前提示“权限不足”

因为 Docker 容器里看到的宿主机访问来源，不一定是 `127.0.0.1`，很多时候会被识别成桥接 IP。

现在这套脚本已经做了两件事：

- 配置里允许管理端从宿主访问
- 端口只绑定到 `127.0.0.1`

这样本地可用，同时不把服务裸奔到整个局域网。

### 14.3 为什么我没有认证文件

两种情况：

- 你是全新用户，本来就没有
- 你以前的数据不在默认旧目录 `~/.cli-proxy-api`

这种情况下，去管理面板重新登录 OAuth，或者手工把认证文件放到：

```bash
~/.config/cliproxyapi-local/auths
```

然后执行：

```bash
./scripts/cliproxy-local.sh restart
```

### 14.4 为什么端口冲突

如果某个端口被占了，启动时会报错。

解决方法很简单，换端口：

```bash
CLIPROXY_PORT_8317=9317 ./scripts/cliproxy-local.sh start
```

### 15.5 为什么 update 失败

常见原因：

- Docker 没启动
- 仓库里有已跟踪修改
- 网络不通，拉不到远端仓库或镜像

先看：

```bash
./scripts/cliproxy-local.sh status
./scripts/cliproxy-local.sh logs
git status
```

### 15.6 为什么 deploy-package 提示包不对

最常见就是平台包下错了。

这台机器当前应该下的是：

```bash
CLIProxyAPI_<版本>_linux_arm64.tar.gz
```

不是：

- `darwin_arm64`
- `darwin_amd64`
- `windows_amd64`

原因不复杂：脚本虽然在 mac 上跑，但服务还是跑在 Docker 里的 Linux 容器里。

## 16. 推荐使用习惯

推荐就按下面这套来，别东一榔头西一棒子：

### 15.1 日常使用

```bash
./scripts/cliproxy-local.sh start
./scripts/cliproxy-local.sh logs
./scripts/cliproxy-local.sh status
```

### 15.2 纯使用者更新

```bash
./scripts/cliproxy-local.sh deploy-package
```

### 15.3 自己维护源码的人更新

```bash
./scripts/cliproxy-local.sh update
./scripts/cliproxy-local.sh rebuild
```

### 15.4 改配置后生效

```bash
./scripts/cliproxy-local.sh restart
```

### 15.5 尽量不要做的事

- 不要长期手改仓库里的 `docker-compose.yml`
- 不要把本地配置文件塞回仓库
- 不要把认证文件放回仓库目录
- 不要一边手工 `docker compose up`，一边又让脚本接管

## 17. 一句话总结

如果你只是想更新运行版本，优先记这个：

```bash
./scripts/cliproxy-local.sh deploy-package
```

如果你自己还在跟源码维护，就记这个：

```bash
./scripts/cliproxy-local.sh update
```

如果你只记一个地址：

```bash
http://127.0.0.1:8317/management.html
```

如果你只记一个本地目录：

```bash
~/.config/cliproxyapi-local
```

剩下那些杂活，脚本已经替你兜了大半。别再自己把仓库改成一锅粥，那真是给未来的自己上强度。
