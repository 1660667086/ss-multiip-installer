# ss-multiip-installer

单独仓库版：一键安装 Shadowsocks-libev + simple-obfs，并自动按服务器多 IP 生成同端口节点。

默认配置：

```text
端口: 80
密码: 1
加密: aes-128-gcm
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
sudo PORT=443 PASSWORD='your-password' METHOD='aes-128-gcm' ./install-ss-multiip.sh
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
停掉原 shadowsocks-libev.service，避免占用 0.0.0.0:端口
启动新的多 IP 服务并设置开机自启
```

## 说明

这个仓库不修改 `1660667086/123`。如果系统源无法安装 `shadowsocks-libev` 或 `simple-obfs`，请先用原来的 `ss-plugins-fixed` 安装基础环境，再运行本脚本做多 IP 配置。
