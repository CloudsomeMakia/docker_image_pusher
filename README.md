# Docker Images Pusher

使用Github Action将国外的Docker镜像转存到阿里云私有仓库，供国内服务器使用，免费易用<br>
- 支持DockerHub, gcr.io, k8s.io, ghcr.io等任意仓库<br>
- 支持最大40GB的大型镜像<br>
- 使用阿里云的官方线路，速度快<br>

视频教程：https://www.bilibili.com/video/BV1Zn4y19743/

作者：**[技术爬爬虾](https://github.com/tech-shrimp/me)**<br>
B站，抖音，Youtube全网同名，转载请注明作者<br>

## 使用方式


### 配置阿里云
登录阿里云容器镜像服务<br>
https://cr.console.aliyun.com/<br>
启用个人实例，创建一个命名空间（**ALIYUN_NAME_SPACE**）
![](/doc/命名空间.png)

访问凭证–>获取环境变量<br>
用户名（**ALIYUN_REGISTRY_USER**)<br>
密码（**ALIYUN_REGISTRY_PASSWORD**)<br>
仓库地址（**ALIYUN_REGISTRY**）<br>

![](/doc/用户名密码.png)


### Fork本项目
Fork本项目<br>
#### 启动Action
进入您自己的项目，点击Action，启用Github Action功能<br>
#### 配置环境变量
进入Settings->Secret and variables->Actions->New Repository secret
![](doc/配置环境变量.png)
将上一步的**四个值**<br>
ALIYUN_NAME_SPACE,ALIYUN_REGISTRY_USER，ALIYUN_REGISTRY_PASSWORD，ALIYUN_REGISTRY<br>
配置成环境变量，原来的这 **4 个 Secrets 仍然都需要**。<br>
再新增 **2 个 Repository Secrets**：<br>
- **IMAGE_PUSH_WEBHOOK_URL**：本 bot 的完整 webhook URL。
- **IMAGE_PUSH_WEBHOOK_AUTHORIZATION**：从本 bot 面板复制的**完整请求头行**，必须整行粘贴；如果已含 `Authorization: ` 前缀，也原样保留，不要自行再加 `Authorization:` 或 `Bearer` 前缀。

### 成功通知
只有 images.txt 中全部镜像 pull/tag/push 成功后，才向 webhook 发送一次 JSON POST 成功通知。<br>
任一镜像失败，或者上述 2 个新增 Secret 为空或缺失，job 都会失败，不发送 success 通知。<br>
通知连接超时为 10 秒，每次请求最多 30 秒；非 2xx 或请求失败（含超时）最多尝试 3 次，间隔 1、2 秒。重试仍失败则 job 失败，不把该次当作成功通知；已推送的镜像不会回滚。<br>
通知包含源镜像、完整目标引用、指定的平台及可靠取得的源 RepoDigest（无法确认则省略）。可用 payload 中的 **run_url** 或 GitHub Actions 运行页做人工核验。<br>
重试、超时或重跑可能造成重复通知，接收方应使用 **run_id / run_attempt** 去重：同次尝试按二者组合去重；若跨重跑也只处理一次，则按 run_id 去重并记录 run_attempt。

### 添加镜像
打开images.txt文件，添加你想要的镜像 
可以加tag，也可以不用(默认latest)<br>
可添加 --platform=xxxxx 的参数指定镜像架构<br>
可使用 k8s.gcr.io/kube-state-metrics/kube-state-metrics 格式指定私库<br>
可使用 #开头作为注释<br>
![](doc/images.png)
文件提交后，自动进入Github Action构建

### 使用镜像
回到阿里云，镜像仓库，点击任意镜像，可查看镜像状态。(可以改成公开，拉取镜像免登录)
![](doc/开始使用.png)

在国内服务器pull镜像, 例如：<br>
```
docker pull registry.cn-hangzhou.aliyuncs.com/shrimp-images/alpine
```
registry.cn-hangzhou.aliyuncs.com 即 ALIYUN_REGISTRY(阿里云仓库地址)<br>
shrimp-images 即 ALIYUN_NAME_SPACE(阿里云命名空间)<br>
alpine 即 阿里云中显示的镜像名<br>

### 多架构
需要在images.txt中用 --platform=xxxxx手动指定镜像架构
指定后的架构会以前缀的形式放在镜像名字前面
![](doc/多架构.png)

### 镜像重名
程序自动判断是否存在名称相同, 但是属于不同命名空间的情况。
如果存在，会把命名空间作为前缀加在镜像名称前。
例如:
```
xhofe/alist
xiaoyaliu/alist
```
![](doc/镜像重名.png)

### 定时执行
修改/.github/workflows/docker.yaml文件
添加 schedule即可定时执行(此处cron使用UTC时区)
![](doc/定时执行.png)
