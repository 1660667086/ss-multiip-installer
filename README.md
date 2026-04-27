# ss-multiip-installer

单独仓库版：自动按服务器多 IP 生成同端口 Shadowsocks 节点。支持原脚本安装出来的 `ss-libev`、`ss-rust`、`go-ss2`，并沿用 `/etc/shadowsocks/config.json` 里的加密、密码、插件和插件参数。

如果服务器还没有任何 Shadowsocks 服务端，脚本会优先用系统源快速补齐 `shadowsocks-libev + simple-obfs`；如果系统源不可用，可显式回退到原来的 `1660667086/123` 安装脚本。

默认配置：

```text
端口: 80
密码: 1
加密: aes-256-gcm
插件: obfs-server
插件参数: obfs=http
```

## 一键安装

仓库创建后，把命令里的仓库名替换成真实仓库名：

```bash
cd /root
rm -rf /root/ss-multiip-installer
rm -f install-ss-multiip.sh
curl -fL -o install-ss-multiip.sh https://raw.githubusercontent.com/1660667086/ss-multiip-installer/master/install-ss-multiip.sh
chmod +x install-ss-multiip.sh
sudo ./install-ss-multiip.sh
```

如果仓库默认分支是 `main`，把 URL 里的 `master` 改成 `main`。

## 自定义参数

```bash
sudo PORT=443 PASSWORD='your-password' METHOD='aes-256-gcm' ./install-ss-multiip.sh
```

显式使用原安装脚本：

```bash
sudo INSTALL_UPSTREAM=1 ./install-ss-multiip.sh
```

如果机器上同时残留多个 Shadowsocks 服务端，可以指定多 IP 使用哪一种：

```bash
sudo SS_IMPL=ss-libev ss-multiip
sudo SS_IMPL=ss-rust ss-multiip
sudo SS_IMPL=go-ss2 ss-multiip
```

## 后续新增 IP

安装完成后会生成命令：

```bash
ss-multiip
```

服务器新增或删除 IP 后，重新运行：

```bash
sudo ss-multiip
```

脚本会自动：

```text
检测本机 IPv4 网卡地址
检测每个网卡对应的公网出口 IP
生成 /etc/shadowsocks/config-ipN.json
生成 /etc/systemd/system/ss-ipN.service
停掉旧 ss-ip*.service
停掉原 shadowsocks-libev/shadowsocks-rust/go-shadowsocks2 服务，避免占用 0.0.0.0:端口
启动新的多 IP 服务并设置开机自启
```

## 说明

这个仓库不修改 `1660667086/123`。默认优先沿用已经安装好的 Shadowsocks 版本；没有服务端时才走系统源快速安装，避免源码编译拖慢小机器。已有 `/etc/shadowsocks/config.json` 时，脚本只改监听端口和绑定方式，保留原密码、加密方式和插件参数；如果原配置没有插件，也不会强行加插件。

脚本会预先设置非交互安装环境，并预配置 `iptables-persistent`，减少安装时卡在保存防火墙规则、`needrestart` 或未完成 `dpkg` 配置阶段的概率。
