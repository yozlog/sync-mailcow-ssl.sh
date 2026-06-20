[English](README.md) | [繁體中文](README.zh-TW.md) | [한국어](README.ko.md)

# Mailcow SSL 同步與 SNI 配置腳本

此腳本用於自動將由外部 ACME Companion 產生的獨立 Let's Encrypt SSL 憑證同步至 Mailcow 容器卷中，並產生對應的 SNI 設定檔（`domains` 宣告），使 Dovecot (IMAP/POP3) 與 Postfix (SMTP) 支援多網域獨立憑證。

## 背景說明

基於安全考量，Mailcow 的網頁管理介面（WebUI）不對公網開放（不映射或限制公網 80 與 443 埠的存取）。

由於 Mailcow 內建的 ACME 容器僅支援 HTTP-01 驗證，在不對外開放 80 埠的情況下無法自動申請與更新憑證，因此在 `mailcow.conf` 中已將設定改為 `SKIP_LETS_ENCRYPT=y`。

為了解決憑證自動更新的需求，本方案採用外部 [nginx-proxy](https://github.com/nginx-proxy/nginx-proxy) 與 [acme-companion](https://github.com/nginx-proxy/acme-companion) 容器，透過 DNS-01 驗證方式（例如 Cloudflare DNS API）在外部自動申請與更新憑證。此腳本即為在此架構下，將外部更新後的憑證安全同步至 Mailcow 並套用 SNI 對應的替代解決方案。

## 主要功能

* **獨立憑證同步**：自動從 Nginx Proxy 憑證目錄同步 `fullchain.pem` 與 `key.pem` 至 Mailcow SSL 目錄。
* **安全權限設定**：同步後自動修正憑證檔案權限（憑證為 `644`，私鑰為 `600`）。
* **SNI 自動映射**：自動在各網域目錄下產生 `domains` 宣告檔案，觸發 Mailcow 在啟動時自動生成 `sni.conf` (Dovecot) 與 `sni.map` (Postfix)。
* **最小化重啟**：僅在偵測到憑證或網域配置有更新時，才會重啟 `mailcow-postfix`、`mailcow-dovecot` 與 `mailcow-nginx` 服務，避免不必要的服務中斷。

## 自動生成 SNI 映射？

如果多個郵件網域（例如 `mail.domain1.com`、`mail.domain2.com`、`mail.domain3.com`）共用郵件伺服器，Mailcow 會使用同一張萬用憑證或多網域（SAN）憑證，為了維護不同網域之間的隱私與獨立性，本方案為每個郵件網域申請各自獨立的 Let's Encrypt 憑證。在採用多張獨立憑證的架構下：

1. **SNI 的重要性**：由於不同網域使用不同的憑證與金鑰，Mailcow 的 Dovecot (IMAP/POP3) 與 Postfix (SMTP) 必須能夠在連線時，根據用戶端送出的伺服器名稱（SNI），動態提供對應的 SSL 憑證。
2. **Mailcow 的自動映射機制**：Mailcow 容器在啟動時，其內建的初始化腳本會掃描 `/etc/ssl/mail/`（對應宿主機的 `assets/ssl/`）目錄下的所有子資料夾。如果偵測到子資料夾中含有 `domains` 宣告檔案，Mailcow 就會自動讀取該檔案內容並產生對應的 `sni.conf` (Dovecot) 與 `sni.map` (Postfix) 映射設定。
3. **腳本的角色**：本腳本在同步憑證檔案時，會自動在每個憑證子目錄下建立正確的 `domains` 檔案，藉此觸發並完成 Mailcow 的 SNI 自動映射配置。

## 前置需求

### 系統環境

* Linux 作業系統
* Docker 與 Docker Compose 運作環境
* 已部署之 Mailcow 郵件伺服器

### 憑證來源

* 使用 Nginx Proxy ACME Companion 透過 DNS-01 (如 Cloudflare API) 取得之獨立 SSL 憑證。
* 憑證儲存於 Nginx Proxy 容器卷（預設為 `/var/lib/docker/volumes/nginx-proxy-certs/_data/`）。

### 注意事項

以下設定與路徑，在使用前需特別注意並配合調整：

1. **宿主機 Docker 卷路徑 (Docker Volume Paths)**：
   * 預設路徑 `/var/lib/docker/volumes/...` 是以宿主機採用預設 Docker 資料目錄（Docker Root Dir）及使用具名卷（Named Volumes）為前提。
   * 若 Docker 採用自訂資料目錄（例如 `/home/docker/` 或掛載至其他硬碟），或是採用綁定掛載（Bind Mounts，例如直接掛載 Mailcow 目錄下的 `./data/assets/ssl`），請務必將腳本中的來源路徑與目標路徑修正為實際的絕對路徑。
2. **Mailcow 容器名稱 (Mailcow Container Names)**：
   * 腳本內重啟服務指令為 `docker restart mailcow-postfix mailcow-dovecot mailcow-nginx`。
   * 若在 `mailcow.conf` 中修改了專案名稱（`COMPOSE_PROJECT_NAME`），或是透過 Portainer 部署並使用了自訂 Stack 名稱，容器名稱可能會被加上不同的前綴（例如 `mailcow-postfix-1`、`my-mail-postfix`）。請先透過 `docker ps` 確認實際的容器名稱後，對應修改腳本中的 `docker restart` 對象。

## 安裝步驟

1. 建立腳本目錄並將腳本複製至系統執行路徑：

   ```bash
   sudo cp main.sh /usr/local/bin/sync-mailcow-ssl.sh
   sudo chmod +x /usr/local/bin/sync-mailcow-ssl.sh

   # 將 /usr/local/bin 替換為欲存放腳本之路徑
   ```

## 腳本自訂說明

在使用前，必須根據實際的環境，修改 `main.sh` 中的同步項目。需修改的部分位於腳本後半段的 `sync_cert` 呼叫：

```bash
# 格式：
# sync_cert "外部憑證來源目錄" "Mailcow憑證目標目錄" "憑證對應的網域名稱"

# 1. 同步預設郵件憑證（當用戶端未送出 SNI 時的預設備用憑證）
sync_cert \
  "/var/lib/docker/volumes/nginx-proxy-certs/_data/mail.domain1.com" \
  "/var/lib/docker/volumes/mailcow_data/_data/assets/ssl" \
  "mail.domain1.com"

# 2. 同步網域 1 的 SNI 憑證
sync_cert \
  "/var/lib/docker/volumes/nginx-proxy-certs/_data/mail.domain1.com" \
  "/var/lib/docker/volumes/mailcow_data/_data/assets/ssl/mail.domain1.com" \
  "mail.domain1.com"

# 2. 同步網域 2 的 SNI 憑證
sync_cert \
  "/var/lib/docker/volumes/nginx-proxy-certs/_data/mail.domain2.com" \
  "/var/lib/docker/volumes/mailcow_data/_data/assets/ssl/mail.domain2.com" \
  "mail.domain2.com"
```

使用者需自行修改：

1. 外部憑證來源路徑（例如將 `/var/lib/docker/volumes/nginx-proxy-certs/_data/` 替換為實際的憑證儲存路徑）。
2. Mailcow 容器卷路徑（例如將 `/var/lib/docker/volumes/mailcow_data/_data/` 替換為實際的 Mailcow 資料目錄）。
3. 各網域呼叫的網域字串參數（例如 `mail.domain1.com`）。

## 執行與自動化

### 手動執行

```bash
sudo /usr/local/bin/sync-mailcow-ssl.sh
```

### 排程自動化

建議將腳本加入 Cron 排程，每日自動偵測憑證更新並進行同步。

1. 編輯系統 Cron 排程：

   ```bash
   sudo crontab -e
   ```

2. 新增以下設定（每日凌晨 3:00 執行）：

   ```cron
   0 3 * * * /usr/local/bin/sync-mailcow-ssl.sh >/dev/null 2>&1
   ```

## 目錄結構參考

同步完成後，Mailcow 的 SSL 目錄結構如下：

```text
/var/lib/docker/volumes/mailcow_data/_data/assets/ssl/
├── cert.pem (預設憑證)
├── key.pem (預設金鑰)
├── domains (預設憑證網域宣告)
├── mail.domain1.com/ (網域 1)
│   ├── cert.pem
│   ├── key.pem
│   └── domains
├── mail.domain2.com/ (網域 2)
│   ├── cert.pem
│   ├── key.pem
│   └── domains
└── mail.domain3.com/ (網域 C)
    ├── cert.pem
    ├── key.pem
    └── domains
```
