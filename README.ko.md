[English](README.md) | [繁體中文](README.zh-TW.md) | [한국어](README.ko.md)

# Mailcow SSL 동기화 및 SNI 설정 스크립트

본 스크립트는 외부 ACME Companion에 의해 생성된 독립적인 Let's Encrypt SSL 인증서를 Mailcow 컨테이너 볼륨으로 자동 동기화하고, 이에 대응하는 SNI 설정(`domains` 메타데이터 파일)을 생성하여 Dovecot (IMAP/POP3) 및 Postfix (SMTP)가 여러 도메인에 대해 독립된 인증서를 지원하도록 구성함.

## 배경 설명

보안상의 이유로 Mailcow의 웹 관리 인터페이스(WebUI)는 공망에 노출되지 않도록 설정되어 있습니다 (공망으로부터의 80 및 443 포트 접근이 제한되거나 매핑되지 않음).

Mailcow 내장 ACME 컨테이너는 HTTP-01 챌린지만 지원하므로, 80 포트를 외부에 개방하지 않는 상태에서는 인증서를 자동으로 신청 및 갱신할 수 없습니다. 이에 따라 `mailcow.conf` 파일 내의 설정이 `SKIP_LETS_ENCRYPT=y`로 변경되었습니다.

인증서 자동 갱신 요구사항을 해결하기 위해, 본 설정에서는 외부 [nginx-proxy](https://github.com/nginx-proxy/nginx-proxy) 및 [acme-companion](https://github.com/nginx-proxy/acme-companion) 컨테이너를 활용하여 DNS-01 챌린지(예: Cloudflare DNS API)를 통해 인증서를 외부에서 자동으로 신청 및 갱신합니다. 본 스크립트는 이와 같은 아키텍처 하에서 외부에서 갱신된 인증서를 Mailcow에 안전하게 동기화하고 이에 대응하는 SNI 설정을 적용하기 위한 대체 솔루션으로 작성되었습니다.

## 주요 기능

* **독립 인증서 동기화**: Nginx Proxy 인증서 디렉터리로부터 `fullchain.pem` 및 `key.pem` 파일을 Mailcow SSL 디렉터리로 자동 동기화함.
* **안전한 권한 설정**: 동기화 후 인증서 파일 권한을 자동으로 수정함 (인증서는 `644`, 개인키는 `600`).
* **자동 SNI 매핑**: 각 도메인 하위 디렉터리 내에 `domains` 메타데이터 파일을 자동으로 생성하여, Mailcow 시작 시 Dovecot용 `sni.conf` 및 Postfix용 `sni.map`이 자동으로 생성되도록 유도함.
* **최소한의 재시작**: 인증서 또는 도메인 설정 변경 사항이 감지되었을 때만 `mailcow-postfix`, `mailcow-dovecot`, `mailcow-nginx` 서비스를 재시작하여 불필요한 서비스 중단을 방지함.

## 자동 SNI 매핑?

여러 메일 도메인(예: `mail.domain1.com`, `mail.domain2.com`, `mail.domain3.com`)이 메일 서버를 공유하는 경우, Mailcow는 단일 와일드카드 인증서나 다중 도메인(SAN) 인증서를 사용하게 됩니다. 서로 다른 도메인 간의 프라이버시와 격리를 보장하기 위해, 본 솔루션은 각 메일 도메인마다 독립적인 Let's Encrypt 인증서를 사용합니다. 이처럼 여러 장의 독립된 인증서를 사용하는 아키텍처 하에서:

1. **SNI의 필요성**: 도메인마다 서로 다른 인증서와 개인키를 사용하므로, Mailcow의 Dovecot (IMAP/POP3) 및 Postfix (SMTP)는 클라이언트가 연결 시 전송하는 서버 이름(SNI)에 따라 알맞은 SSL 인증서를 동적으로 제공해야 합니다.
2. **Mailcow의 자동 매핑 메커니즘**: Mailcow 컨테이너가 시작될 때 내장된 초기화 스크립트가 `/etc/ssl/mail/`(호스트의 `assets/ssl/`에 매핑됨) 하위의 모든 디렉터리를 스캔합니다. 디렉터리 내에 `domains` 메타데이터 파일이 감지되면 Mailcow가 이를 자동으로 읽어 Dovecot용 `sni.conf` 및 Postfix용 `sni.map` 매핑 설정을 생성합니다.
3. **스크립트의 역할**: 본 스크립트는 인증서 동기화 시 각 인증서 하위 디렉터리에 올바른 `domains` 파일을 자동으로 생성하여 Mailcow가 SNI 매핑 설정을 자동으로 구성하도록 트리거하는 역할을 합니다.

## 요구사항

### 시스템 환경

* Linux 운영체제
* Docker 및 Docker Compose 실행 환경
* 배포 완료된 Mailcow 메일 서버

### 인증서 소스

* Nginx Proxy ACME Companion을 통해 DNS-01 챌린지(예: Cloudflare API)로 획득한 독립형 SSL 인증서.
* Nginx Proxy 컨테이너 볼륨에 저장된 인증서 (기본 경로: `/var/lib/docker/volumes/nginx-proxy-certs/_data/`).

### 배포 주의사항

다음 설정 및 경로는 사용 전에 특히 주의하여 조정해야 합니다:

1. **호스트 Docker 볼륨 경로**:
   * 기본 경로인 `/var/lib/docker/volumes/...`는 호스트가 기본 Docker 데이터 디렉터리(Docker Root Dir)를 사용하고 이름이 지정된 볼륨(Named Volumes)을 사용하는 것을 전제로 합니다.
   * 만약 Docker 데이터 디렉터리를 커스텀하여 사용하거나(예: `/home/docker/` 혹은 다른 하드 드라이브에 마운트), 바인드 마운트(Bind Mounts, 예: Mailcow 디렉터리 내의 `./data/assets/ssl`을 직접 마운트)를 사용하는 경우 스크립트의 소스 및 대상 경로를 실제 절대 경로로 수정해야 합니다.
2. **Mailcow 컨테이너 이름**:
   * 스크립트 내 서비스 재시작 명령은 `docker restart mailcow-postfix mailcow-dovecot mailcow-nginx`입니다.
   * `mailcow.conf` 파일에서 프로젝트 이름(`COMPOSE_PROJECT_NAME`)을 수정했거나, Portainer를 통해 커스텀 스택 이름으로 배포한 경우 컨테이너 이름에 다른 접두사가 붙을 수 있습니다(예: `mailcow-postfix-1`, `my-mail-postfix`). 반드시 `docker ps`를 통해 실제 컨테이너 이름을 확인한 후 스크립트의 `docker restart` 대상을 수정해 주십시오.

## 설치 방법

1. 스크립트를 시스템 실행 경로로 복사하고 실행 권한을 부여함:

   ```bash
   sudo cp main.sh /usr/local/bin/sync-mailcow-ssl.sh
   sudo chmod +x /usr/local/bin/sync-mailcow-ssl.sh

   # /usr/local/bin 경로를 스크립트를 저장할 실제 경로로 변경 가능
   ```

## 스크립트 사용자 설정

사용하기 전에 실제 환경에 맞추어 `main.sh` 파일 내의 동기화 항목을 수정해야 합니다. 수정해야 할 부분은 스크립트 하단에 위치한 `sync_cert` 호출부입니다:

```bash
# 형식:
# sync_cert "외부 인증서 소스 디렉터리" "Mailcow 인증서 대상 디렉터리" "인증서에 대응하는 도메인 이름"

# 1. 기본 메일 인증서 동기화 (클라이언트가 SNI를 전송하지 않을 때 사용하는 예비 인증서)
sync_cert \
  "/var/lib/docker/volumes/nginx-proxy-certs/_data/mail.domain1.com" \
  "/var/lib/docker/volumes/mailcow_data/_data/assets/ssl" \
  "mail.domain1.com"

# 2. 도메인 1의 SNI 인증서 동기화
sync_cert \
  "/var/lib/docker/volumes/nginx-proxy-certs/_data/mail.domain1.com" \
  "/var/lib/docker/volumes/mailcow_data/_data/assets/ssl/mail.domain1.com" \
  "mail.domain1.com"

# 2. 도메인 2의 SNI 인증서 동기화
sync_cert \
  "/var/lib/docker/volumes/nginx-proxy-certs/_data/mail.domain2.com" \
  "/var/lib/docker/volumes/mailcow_data/_data/assets/ssl/mail.domain2.com" \
  "mail.domain2.com"
```

사용자가 직접 수정해야 하는 항목은 다음과 같습니다:

1. 외부 인증서 소스 경로 (예: `/var/lib/docker/volumes/nginx-proxy-certs/_data/` 부분을 실제 인증서가 저장된 경로로 변경).
2. Mailcow 컨테이너 볼륨 경로 (예: `/var/lib/docker/volumes/mailcow_data/_data/` 부분을 실제 Mailcow 데이터 디렉터리로 변경).
3. 각 호출부에 인자로 전달되는 도메인 문자열 (예: `mail.domain1.com`).

## 실행 및 자동화

### 수동 실행

```bash
sudo /usr/local/bin/sync-mailcow-ssl.sh
```

### 크론탭 등록을 통한 자동화

갱신된 인증서를 정기적으로 감지하고 적용하기 위해 크론탭(Cron) 등록을 권장함.

1. 시스템 크론탭 설정 편집:

   ```bash
   sudo crontab -e
   ```

2. 아래 설정을 추가함 (매일 새벽 3시에 실행):

   ```cron
   0 3 * * * /usr/local/bin/sync-mailcow-ssl.sh >/dev/null 2>&1
   ```

## 디렉터리 구조 예시

동기화가 완료된 후 Mailcow SSL 디렉터리 구조는 다음과 같음:

```text
/var/lib/docker/volumes/mailcow_data/_data/assets/ssl/
├── cert.pem (기본 인증서)
├── key.pem (기본 개인키)
├── domains (기본 인증서 도메인 메타데이터)
├── mail.domain1.com/ (도메인 1)
│   ├── cert.pem
│   ├── key.pem
│   └── domains
├── mail.domain2.com/ (도메인 2)
│   ├── cert.pem
│   ├── key.pem
│   └── domains
└── mail.domain3.com/ (도메인 3)
    ├── cert.pem
    ├── key.pem
    └── domains
```
