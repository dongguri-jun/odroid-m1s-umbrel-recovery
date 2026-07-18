# ODROID M1S Umbrel 설치 방법

## [English guide](README.en.md)

> **비공식 안내 / Disclaimer**
>
> 이 저장소는 **동구리 개인이 비영리적으로 정리한 자료**입니다. 바이너리리스트(주), 제로니모 브랜드, Umbrel, ODROID(Hardkernel) 어느 쪽과도 공식적으로 무관합니다.
>
> 이 저장소의 가이드와 스크립트는 MIT License로 공개됩니다. 단, Umbrel 자체는 **PolyForm Noncommercial 1.0.0** 라이선스를 따르므로, Umbrel 사용·파생 운영·지원 형태는 해당 라이선스의 비영리 조건을 별도로 확인해 주세요.
>
> 본 가이드의 절차는 **저장장치(SSD)의 데이터를 모두 삭제**합니다. 설치 과정에서 디바이스 손상이나 데이터 손실이 발생할 수 있으니, 진행 전 **중요한 데이터는 반드시 백업**해 주세요. 본 가이드는 무상 자료이며, **설치 결과에 대한 책임은 사용자 본인에게 있습니다.**
>
> **전원 케이블을 바로 뽑지 마세요.** Bitcoin 노드가 실행 중일 때 전원을 갑자기 끄면 Bitcoin 데이터가 손상될 수 있습니다. 끌 때는 Umbrel 웹 화면에서 **Settings → Shut down** 또는 **설정 → 종료**를 누른 뒤 **“종료 완료 / 이제 디바이스 전원을 분리해도 좋습니다.”** 화면이 뜰 때까지 기다리세요. 자세한 내용은 아래 **13. 안전하게 종료하기**를 확인하세요.

---

이 문서는 **비개발자도 순서대로 따라할 수 있게** ODROID M1S에 Umbrel을 설치하는 방법을 정리한 가이드입니다.

이 저장소에서 실제로 자주 사용하는 파일은 아래 6개입니다.

- `scripts/m1s-clean-install-umbrel.sh` — Umbrel 설치 스크립트
- `scripts/m1s-initial-setup.sh` — 초기 설정 스크립트 (계정 생성 / `umbrel` 호스트 이름 유지)
- `scripts/m1s-update-umbrel.sh` — 이미 설치된 장비를 최신 버전으로 올리는 업데이트 스크립트
- `scripts/m1s-update-system-packages.sh` — Ubuntu 보안/커널 관련 패키지를 업데이트하고 필요하면 재부팅하는 스크립트
- `scripts/m1s-start-bitcoin-chainstate-rebuild.sh` — Bitcoin chainstate 재구축 시작 스크립트
- `scripts/m1s-check-bitcoin-recovery-status.sh` — Bitcoin 복구 상태 확인 스크립트

이 스크립트는 실제 ODROID M1S 실기기에서 테스트했습니다.

ODROID M1S는 안정적이고 비교적 저렴하게 사용할 수 있는 장점이 있습니다.
다만 성능이 아주 높은 장비는 아니어서, 무거운 작업을 한꺼번에 진행하거나 다운로드·동기화 작업이 이어질 때는 시간이 꽤 걸릴 수 있습니다.

---

## 0. 아주 중요한 경고

이 설치 방법은 **SSD 데이터를 모두 삭제하는 방식**입니다.

즉:
- SSD 안에 들어 있던 데이터는 전부 삭제됩니다.
- 기존 노드 데이터도 보존되지 않습니다.
- Ubuntu 기본 시스템은 유지됩니다.

SSD 데이터를 지우면 안 되는 경우에는 진행하지 마세요.

---

## 1. 준비물

아래 준비물이 필요합니다.

- **ODROID M1S 본체 (반드시 8GB 모델 권장, 4GB 모델 비권장)** (ODROID 공식 구매 홈페이지 : https://www.hardkernel.com/)
- **전원 케이블**
- **모니터**
- **Hdmi to Hdmi 케이블**
- **USB 키보드**
- **유선 인터넷 연결(랜선, 이더넷 케이블)**
- **2TB 이상 NVMe SSD**
- 설치 후 Umbrel 웹페이지를 열 수 있는, **ODROID M1S와 같은 로컬 네트워크에 연결된 컴퓨터 또는 휴대폰 1대**

중요:
- ODROID M1S는 가능하면 **반드시 8GB 모델**을 준비하는 것을 권장합니다.
- **4GB 모델은 RAM 용량이 너무 적어서** Umbrel과 Bitcoin 노드를 같이 운용할 때 여유가 부족할 수 있습니다.

필수:
- 설치 중 반드시 **유선 네트워크 연결(랜선, 이더넷 케이블)** 을 사용해야 합니다.
- **ODROID M1S는 Wi‑Fi 연결이 불가능하므로**, 반드시 유선 네트워크 환경에서 진행해야 합니다.

### SSD 선택 시 주의

ODROID M1S는 NVMe SSD를 사용할 수 있습니다.

대부분의 NVMe SSD는 사용할 수 있지만, 일부 SSD는 ODROID M1S에서 인식되지 않거나 재부팅 후 사라지는 사례가 보고되어 있습니다.  
이 저장소의 설치 스크립트는 이런 SSD 인식 문제를 줄이기 위한 안정화 설정을 자동으로 적용합니다.

가능하면 아래처럼 동작이 확인된 SSD를 사용하는 것을 권장합니다.

- Crucial P3 / P3 Plus
- Kingston NV1
- PNY CS1031
- Samsung PM9A1
- Samsung 970 EVO
- Samsung 970 EVO Plus 1TB
- Western Digital SN550

아래 SSD는 ODROID M1S에서 문제가 보고된 적이 있어, 가능하면 피하는 것을 권장합니다.

- Silicon Power NVMe SSD
- Samsung 970 EVO Plus 2TB
- WD Green WDS480G3G0B

추천 SSD를 구하기 어렵다면 너무 걱정하지 않아도 됩니다.  
제품명에 **M.2 NVMe 2280 SSD**라고 적힌 SSD를 고르면 대부분 사용할 수 있습니다.
다만 저렴한 중국산 SSD가 아닌 대기업의 공식 SSD를 사용하셔야 합니다.
- "M.2 = SSD의 물리적 규격"
- "NVMe = SSD가 데이터를 주고받는 통신 방식 ~~SATA~~"
- "2280 = SSD의 물리적 크기 ~~2230~~, ~~2242~~"

단, `M.2 SATA` SSD는 방식이 달라 사용할 수 없습니다.

Bitcoin 노드 용도라면 **2TB 이상 SSD**를 권장합니다.

---

## 2. 장비 연결

다음 순서대로 연결합니다.

1. ODROID M1S에 **NVMe SSD**를 연결합니다.
2. **HDMI 케이블**로 모니터를 연결합니다.
3. **USB 키보드**를 연결합니다.
4. **이더넷 케이블**을 반드시 연결합니다.
5. 마지막으로 **전원 케이블**을 연결합니다.

---

## 3. Ubuntu Server가 이미 설치된 상태인지 확인

이 가이드는 아래 조건에서 동작합니다.

- 기기: **Hardkernel ODROID-M1S**
- OS: **Ubuntu 20.04 / 22.04 / 24.04 Server**

이미 Ubuntu가 설치되어 있고 로그인 가능한 상태여야 합니다.

만약 Ubuntu가 아직 설치되지 않았다면, 먼저 Ubuntu Server를 설치한 뒤 이 가이드를 진행하세요.

---

## 4. 터미널 열기

ODROID M1S의 전원을 켜고 **HDMI로 모니터를 연결하면**, Ubuntu Server 기준으로 명령어를 입력할 수 있는 화면이 바로 나타납니다.

이 가이드는 **리눅스 서버(Ubuntu Server)** 기준으로 설명합니다.

즉, 데스크톱 화면에서 Terminal 아이콘을 찾는 방식이 아니라, **부팅 후 모니터에 표시되는 명령 입력 화면에서 바로 진행**하면 됩니다.

중요한 건 **명령어를 입력할 수 있는 검은 화면**에서 로그인한 뒤 아래 명령을 순서대로 입력하는 것입니다.

처음 전원을 켠 직후에는 바로 로그인 화면이 나오지 않을 수 있습니다.

실기 기준으로는 **1~3분 정도 기다리면** 로그인 가능한 상태가 됩니다.

여기서부터는 경우를 나눠서 보면 됩니다.

### 4-1. 이미 Ubuntu Server가 설치되어 있는 장비인 경우

이 가이드는 기본적으로 **이미 Ubuntu Server가 설치되어 있는 ODROID M1S**를 기준으로 설명합니다.

이미 Ubuntu Server가 설치된 장비라면, 해당 장비를 처음 설정한 사람이 만든 사용자 이름과 비밀번호로 로그인해야 합니다.

제로니모 쪽에서 세팅된 장비라면 보통 아래 계정으로 로그인합니다.

```text
login: nordin
password: emfTjrwlrms
```

비밀번호 `emfTjrwlrms`는 한글 키보드 기준으로 **“들썩지근”** 을 영문 입력 상태에서 친 값입니다.


다른 장비에서는 사용자 이름과 비밀번호가 다를 수 있습니다. 판매자나 설치 담당자에게 받은 계정 정보를 사용하세요. 위 기본 계정으로 로그인했다면, 설치 후 7번의 초기 설정 단계에서 반드시 새 사용자 계정과 새 비밀번호로 바꾸는 것을 권장합니다.

### 4-2. 새 제품이라 Ubuntu Server부터 직접 설치하는 경우

만약 **새 제품**이라서 먼저 Ubuntu Server를 직접 설치했다면, ODROID 제품군은 기본적으로 아래 계정으로 로그인할 수 있습니다.

```text
login: odroid
password: odroid
```

비밀번호를 입력할 때는 화면에 글자가 보이지 않는 것이 정상입니다. 입력한 뒤 **엔터**를 누르세요.

만약 7번의 초기 설정 단계에서 **새 사용자 계정**을 만든 뒤라면, 그때부터는 위 기본 계정 대신 **직접 만든 새 계정과 비밀번호**로 로그인하면 됩니다.

---

## 5. 저장소 준비

이 저장소를 ODROID M1S 안에 받아야 합니다.

> **참고 — 명령어 입력 방법**
>
> 아래 명령어는 **한 줄씩 따로 입력**해야 합니다. 한 줄을 입력한 뒤에는 반드시 **엔터(Enter)** 키를 눌러 그 명령을 실행하고, 명령이 끝나서 다시 입력을 받을 수 있는 상태가 될 때까지 기다린 다음 **다음 줄을 입력**하세요.

**(1) 패키지 목록을 최신 상태로 갱신합니다.**

```bash
sudo apt update
```

입력 후 **엔터**를 누르세요. 명령이 끝나면 다시 입력을 받을 수 있는 상태가 됩니다.

**(2) `git` 을 설치합니다.**

```bash
sudo apt install -y git
```

입력 후 **엔터**를 누르세요. 설치가 끝날 때까지 기다립니다.

**(3) 저장소를 ODROID M1S 안에 내려받습니다.**

```bash
git clone https://github.com/dongguri-jun/odroid-m1s-umbrel-recovery.git
```

입력 후 **엔터**를 누르세요. 네트워크를 통해 파일이 내려받아집니다.

**(4) 내려받은 폴더 안으로 들어갑니다.**

```bash
cd odroid-m1s-umbrel-recovery
```

입력 후 **엔터**를 누르세요. 이제 다음 단계(6번)의 명령을 실행할 준비가 된 상태입니다.

### `git clone` 이 안 될 때

만약 아래처럼 나오면:

```text
Could not resolve host: github.com
```

아래 명령을 한 줄씩 실행하세요.

```bash
ping -c 3 github.com
curl -I https://github.com
sudo systemctl restart systemd-resolved
```

그 다음 다시 아래 명령을 실행하세요.

```bash
git clone https://github.com/dongguri-jun/odroid-m1s-umbrel-recovery.git
cd odroid-m1s-umbrel-recovery
```

---

## 6. 설치 명령 실행

이제 아래 명령 **1개만 실행**하면 됩니다. 5번과 마찬가지로 **한 줄을 입력한 뒤 엔터(Enter)** 키를 누르세요.

```bash
sudo bash scripts/m1s-clean-install-umbrel.sh --release
```

실행하면 스크립트가 자동으로 아래 작업을 합니다.

1. 기존 앱/컨테이너/노드 관련 서비스 정리
2. NVMe SSD 포맷
3. SSD를 `/mnt/fullnode` 로 마운트
4. `/etc/fstab` 등록
5. Docker 설치
6. Umbrel 실행
7. `umbrel.local` 과 장비 IP 기준 기본 health check 출력

중간에 삭제 경고가 나오면, 화면에 보이는 확인 문구를 그대로 입력하면 됩니다.

실제로는 아래 문구를 입력하게 됩니다.

```text
ERASE-EMMC-AND-FORMAT-SSD-AND-INSTALL-UMBREL
```

문구가 길기 때문에, 틀리지 않게 천천히 그대로 입력하세요.

설치 중 `Waiting for cache lock`, `dpkg lock`, `unattended-upgrades` 같은 문구가 보일 수 있습니다. 최신 스크립트는 이 상황을 자동으로 기다리고 처리하므로, 인터넷에서 본 `sudo rm /var/lib/dpkg/lock*`, `kill -9`, `killall unattended-upgr` 같은 수동 복구 명령을 따라 하지 마세요. 패키지 관리 상태가 더 꼬일 수 있습니다.

---

## 7. 초기 설정 (계정 만들기)

6번의 설치가 끝나면, **자신만의 사용자 계정을 만들 수 있습니다.**

이 단계는 선택 사항입니다. 기존 계정을 그대로 쓰고 싶다면 건너뛰어도 됩니다.

다만, 직접 새 계정을 만들고 비밀번호를 다시 설정하지 않으면, 기본 계정을 그대로 쓰게 되어 **보안에 매우 취약해질 수 있습니다.**

그래서 가능하면 이 단계는 건너뛰지 말고, **반드시 새 사용자 계정과 새 비밀번호로 바꾸는 것을 강력히 권장합니다.**

아래 명령 **1개만 실행**하면 됩니다.

```bash
sudo bash scripts/m1s-initial-setup.sh
```

실행하면 화면에서 다음 항목을 물어봅니다.

1. **새 사용자 이름** — 앞으로 로그인할 때 쓸 이름을 입력합니다.
2. **새 비밀번호** — 비밀번호를 입력합니다. 확인을 위해 한 번 더 입력합니다.

호스트 이름은 `umbrel.local` 접속을 위해 `umbrel`로 유지됩니다. 사용자가 따로 입력할 필요가 없습니다.

요약이 표시되면 `y`를 입력해서 진행합니다.

설정이 끝나면 화면에 안내가 나옵니다. 안내에 따라 다음을 진행하세요.

1. `exit`을 입력해서 로그아웃합니다.
2. 방금 만든 새 계정으로 다시 로그인합니다.
3. 기존 계정을 삭제하려면, 화면에 표시된 삭제 명령을 그대로 입력합니다.

---

## 8. 설치가 끝난 뒤 접속하기

설치가 끝나면 같은 네트워크에 있는 다른 컴퓨터나 휴대폰의 브라우저에서 먼저 아래 주소를 입력합니다.

```text
http://umbrel.local
```

대부분의 경우 이 주소로 바로 접속됩니다.

설치가 끝난 직후 터미널 마지막 부분에는 보통 아래 정보가 함께 표시됩니다.

- LAN interface
- LAN IP
- `http://umbrel.local`
- `http://<장비 IP>`

즉, `umbrel.local` 이 열리지 않더라도 터미널에 표시된 **장비 IP 주소로 바로 접속**하면 됩니다.

중요:
- 접속하는 기기(휴대폰, 컴퓨터)에서 **Tailscale이나 다른 VPN이 켜져 있다면 먼저 끄는 것을 권장합니다.**
- 이런 프로그램이 켜져 있으면 `umbrel.local` 주소가 제대로 열리지 않거나, 엉뚱한 주소로 연결될 수 있습니다.

만약 `umbrel.local` 이 열리지 않으면, 그때는 **터미널 마지막에 표시된 장비 IP를 먼저 시도**하고, 그래도 확인이 필요하면 **Fing 앱에서 IP 주소를 확인한 뒤 브라우저 주소창에 입력**합니다.

Fing 앱은 **구글 플레이스토어**와 **애플 앱스토어**에서 무료로 다운로드할 수 있습니다.

Fing 목록에서 **Generic** 또는 **알 수 없는 기기**처럼 보이는 항목이 있으면, 표시된 IP 주소를 모두 하나씩 브라우저에 입력해 보세요.

그러다 보면 Umbrel 화면이 열리는 IP 주소를 찾을 수 있습니다.

예를 들면:

```text
http://<장비 IP>
```

---

## 9. Umbrel 계정 생성

브라우저에서 Umbrel 화면이 열리면 다음 순서로 진행합니다.

1. **Umbrel 계정 생성**
2. 비밀번호 설정
3. 기본 설정 완료

---

## 10. Bitcoin 노드 앱 설치

Umbrel 계정을 만든 뒤에는 App Store에서 **Bitcoin 노드 앱**을 설치합니다.

설치가 시작되면 화면에서 진행률이 올라가지만, 실기 테스트 기준으로는 **99%에 오래 머무는 것처럼 보일 수 있습니다.**

하지만 실제로는 아래 작업이 계속 진행 중일 수 있습니다.

- Docker 이미지 다운로드
- Bitcoin 컨테이너 생성
- Tor 컨테이너 생성
- Bitcoin Core 헤더 동기화 시작

즉, 99%라고 바로 실패라고 생각하지 마세요. 네트워크 속도나 디스크 상태에 따라 시간이 더 걸릴 수도 있으니, **다른 작업을 하시면서 여유를 가지고 기다려 주세요.**

또한 Bitcoin Core는 **IBD(Initial Block Download, 초기 블록 동기화)** 과정에서 연산이 많이 일어나기 때문에, 한동안 발열이 높아질 수 있습니다.

실사용 기준으로는 동기화가 길어질 때 **작은 손선풍기를 메인보드 위쪽으로 바람이 가게 얹어 두면**, 열을 더 빨리 식히는 데 도움이 될 수 있습니다.

발열이 낮아지면 스로틀링을 줄이는 데 도움이 될 수 있으므로, 경우에 따라 동기화가 더 안정적이고 빠르게 진행될 수 있습니다.

## 11. 운영 스크립트 업데이트 하기

이 저장소에는 ODROID M1S에서 Umbrel을 더 안정적으로 쓰기 위한 **운영 스크립트**들이 들어 있습니다. 설치, 업데이트, 안전 종료, Bitcoin 복구 상태 확인처럼 실제 사용 중에 필요한 작업을 자동으로 처리해 주는 파일들입니다.

사용자들이 겪는 여러 문제를 확인하면서, 이 운영 스크립트도 계속 업데이트하고 있습니다. 예를 들어 설치 후 접속이 잘 안 되는 문제, SSD 마운트 확인, Bitcoin 복구 상태 확인, 안전 종료 처리 같은 부분이 조금씩 개선될 수 있습니다.

그래서 이미 설치가 끝난 장비라도, 시간이 될 때 아래 업데이트를 한 번씩 실행하는 것을 권장합니다. 업데이트하면 기존 데이터나 비밀번호를 지우지 않고, 최신 운영 스크립트와 필요한 수정 사항만 반영합니다. 지금 겪고 있는 문제가 최신 업데이트에서 이미 해결되어 있을 수도 있습니다.

이미 Umbrel 웹 화면에 접속할 수 있다면, 아래 **11-1번의 웹 화면 방법**이 더 쉽습니다. SSH나 모니터/키보드로 직접 터미널에 들어갈 수 있는 분은 **11-2번**으로 진행해도 됩니다.

### 11-1. 운영스크립트 Umbrel 웹 화면에서 업데이트하기 (추천)

이 방법은 별도의 SSH 앱이나 모니터/키보드 없이, Umbrel 웹 화면 안의 Terminal에서 진행하는 방법입니다.

순서는 다음과 같습니다.

1. Umbrel 웹 화면에 로그인합니다.
2. **Settings → Advanced settings → Terminal** 로 이동합니다. 한국어 화면에서는 **설정 → 고급 설정 → 터미널** 로 보일 수 있습니다.
3. 터미널이 열리면, 가장 먼저 아래 한 줄을 입력합니다.

```bash
sudo nsenter -t 1 -m -u -i -n -p -- bash
```

이 명령은 **Umbrel 컨테이너 바깥(=ODROID M1S 호스트) 쉘**로 들어가는 명령입니다. 즉, SSH로 직접 접속한 것과 같은 위치에 들어간 셈이 됩니다.

처음 한 번은 화면에 아래와 같이 비밀번호 입력 안내가 나옵니다.

```text
[sudo] password for umbrel:
```

여기에는 **Umbrel 웹 화면에 로그인할 때 사용하는 비밀번호**를 그대로 입력하면 됩니다. (입력 중에는 글자가 보이지 않는 것이 정상입니다.)

비밀번호가 맞으면 프롬프트가 아래처럼 `root@umbrel:/#` 형태로 바뀝니다. 그러면 호스트 쉘로 들어간 상태입니다.

```text
root@umbrel:/#
```

이 상태에서는 아래 명령을 그대로 입력하면 됩니다. SSH로 접속했을 때와 동일한 명령 세트입니다.

```bash
cd /home/*/odroid-m1s-umbrel-recovery
sudo git -c safe.directory="$(pwd)" fetch https://github.com/dongguri-jun/odroid-m1s-umbrel-recovery.git main
sudo git -c safe.directory="$(pwd)" reset --hard FETCH_HEAD
sudo bash scripts/m1s-update-umbrel.sh --check
sudo bash scripts/m1s-update-umbrel.sh
```

작업이 끝나면 평소대로 터미널 창을 닫으면 됩니다. SSH로 진행할 때와 동일하게 데이터/비밀번호/앱은 그대로 유지됩니다.

주의할 점은 다음과 같습니다.

- 이 방법은 호스트 권한이 있는 쉘로 들어가는 명령이므로, **이 가이드 안에서 안내된 명령 외에 모르는 명령을 함부로 따라 입력하지 마세요.** 이건 SSH로 접속했을 때와 동일한 책임 범위입니다.
- Umbrel/Docker 이미지의 향후 변경에 따라 이 방법이 동작하지 않을 수도 있습니다. 그런 경우에는 아래 11-2번의 SSH/직접 터미널 방식을 사용하면 됩니다.

### 11-2. 운영스크립트 SSH나 직접 연결한 터미널에서 업데이트하기 (고급)

ODROID M1S에 SSH로 접속할 수 있거나, 모니터와 키보드로 직접 로그인한 경우에는 아래 명령을 위에서부터 차례로 입력해도 됩니다.

```bash
cd /home/*/odroid-m1s-umbrel-recovery
sudo git -c safe.directory="$(pwd)" fetch https://github.com/dongguri-jun/odroid-m1s-umbrel-recovery.git main
sudo git -c safe.directory="$(pwd)" reset --hard FETCH_HEAD
sudo bash scripts/m1s-update-umbrel.sh --check
sudo bash scripts/m1s-update-umbrel.sh
```

각 줄이 하는 일:

1. `cd /home/*/odroid-m1s-umbrel-recovery` — 처음 설치할 때 받아 둔 저장소 폴더로 이동합니다. 별표(`*`)는 "어떤 사용자 이름이든 자동으로 찾기"를 의미하므로, 사용자 이름을 직접 입력할 필요가 없습니다.
2. `sudo git -c safe.directory="$(pwd)" fetch https://github.com/dongguri-jun/odroid-m1s-umbrel-recovery.git main` — 장비에 저장된 `origin` 설정을 믿지 않고, 공식 GitHub 저장소에서 최신 변경 내역을 직접 가져옵니다.
3. `sudo git -c safe.directory="$(pwd)" reset --hard FETCH_HEAD` — 방금 공식 저장소에서 가져온 최신 파일 상태와 로컬 파일을 똑같이 맞춥니다. 이 과정에서 로컬의 업데이트 스크립트 자신도 최신 버전으로 교체됩니다.
4. `sudo bash scripts/m1s-update-umbrel.sh --check` — 서비스와 데이터 마이그레이션은 적용하지 않지만, 기본 official-origin auto-sync가 저장소 파일을 갱신할 수 있습니다. **현재 설치된 버전 · 최신 버전 · 적용될 수정 목록**만 보여 줍니다. 이미 최신이면 "No migrations needed" 처럼 안내됩니다.
5. `sudo bash scripts/m1s-update-umbrel.sh` — 실제 업데이트를 적용합니다. 이미 최신이면 아무 작업 없이 끝납니다.

만약 `--check` 결과의 `Script version` 이 `0.5.6` 이하로 나오고 바로 “No migrations needed” 로 끝나면, 그 장비에는 아직 자동 동기화 기능 자체가 없는 상태입니다. 이 경우에만 아래 두 줄을 **처음 한 번만** 실행한 뒤, 위 5줄을 다시 실행하세요.

```bash
sudo git -c safe.directory="$(pwd)" fetch https://github.com/dongguri-jun/odroid-m1s-umbrel-recovery.git main
sudo git -c safe.directory="$(pwd)" reset --hard FETCH_HEAD
```

업데이트 중에는 Umbrel 화면이 잠시 열리지 않을 수 있습니다. 스크립트는 SSD가 `/mnt/fullnode`에 정상 연결되어 있는지 먼저 확인한 뒤, 기존 데이터 위치를 그대로 유지한 상태에서 필요한 부분만 갱신합니다.

내부적으로는 현재 설치 버전에서 최신 버전까지 필요한 단계를 순서대로 적용합니다. 중간에 실패하면 성공한 단계까지만 기록한 뒤 멈추므로, 문제를 해결한 뒤 같은 명령을 다시 실행하면 안전하게 이어집니다.

이미 있는 비밀번호, 앱 데이터, Bitcoin 노드 데이터는 건드리지 않고, 여러 번 실행해도 안전합니다.

## 12. Bitcoin 데이터 복구하기

Bitcoin 노드가 갑자기 멈추거나 연결이 끊겼을 때, 아래 순서로 진행합니다.

### 12-1. 공용 헬스체크와 오류 로그를 먼저 모으기

복구 명령을 바로 실행하기 전에, 먼저 아래 공용 헬스체크 명령으로 현재 상태를 확인하세요.

**Umbrel 웹 Terminal에서 입력하는 방법 (추천)**

1. Umbrel 웹 화면에 로그인합니다.
2. **Settings → Advanced settings → Terminal** 로 이동합니다. 한국어 화면에서는 **설정 → 고급 설정 → 터미널** 로 보일 수 있습니다.
3. 터미널이 열리면 먼저 아래 명령으로 host shell에 들어갑니다.

```bash
sudo nsenter -t 1 -m -u -i -n -p -- bash
```

프롬프트가 `root@umbrel:/#` 형태로 바뀌면, 아래 공용 헬스체크 명령을 입력합니다.

```bash
sudo bash scripts/m1s-check-bitcoin-recovery-status.sh
```

**SSH나 직접 연결한 터미널에서 입력하는 방법 (고급)**

ODROID M1S에 SSH로 접속했거나, 모니터와 키보드로 직접 로그인한 경우에는 아래 공용 헬스체크 명령을 바로 입력하면 됩니다.

```bash
sudo bash scripts/m1s-check-bitcoin-recovery-status.sh
```

이 출력에는 현재 복구 모드, Bitcoin 로그 힌트, 블록 동기화 상태, SSD 마운트 상태, 디스크 여유 공간, 최근 커널 저장장치 오류 힌트가 함께 나옵니다.

가능하면 Bitcoin/Umbrel 오류 로그도 함께 준비하세요. 에러가 시작되는 부분부터 종료 메시지까지 있으면 좋습니다.

잘 모르겠다면 **공용 헬스체크 출력과 오류 로그를 함께** AI에게 복사해서 붙여 넣고 아래처럼 물어보세요.

```text
아래 공용 헬스체크 출력과 오류 로그를 보면
1) chainstate rebuild
2) reindex
3) full resync
중 어떤 복구가 맞아?
그리고 Umbrel Terminal에서 어떤 명령어를 입력하면 돼?

[공용 헬스체크 출력]
여기에 sudo bash scripts/m1s-check-bitcoin-recovery-status.sh 출력 붙여넣기

[오류 로그]
여기에 Bitcoin/Umbrel 오류 로그 붙여넣기
```

복구 방식은 보통 아래 3가지 중 하나입니다.

- **chainstate rebuild** — 블록 데이터는 살리고 chainstate만 다시 만들 때 (가장 먼저 시도)
- **reindex** — blocks는 유지하되 index/chainstate를 더 크게 다시 훑을 때
- **full resync** — 모든 데이터를 지우고 처음부터 다시 받을 때 (가장 마지막 수단)

### 12-2. Umbrel 웹 Terminal에서 복구 명령 실행하기 (추천)

이미 Umbrel 웹 화면에 접속할 수 있다면, 웹 화면 안의 Terminal에서 진행하는 방법이 가장 쉽습니다.

Umbrel 웹 화면 안의 Terminal은 처음에는 **Umbrel 컨테이너 안**이므로, 먼저 host shell로 들어가야 합니다.

1. Umbrel 웹 화면에 로그인
2. **Settings → Advanced settings → Terminal** 로 이동 (한국어: 설정 → 고급 설정 → 터미널)
3. 터미널이 열리면 가장 먼저 아래를 입력

```bash
sudo nsenter -t 1 -m -u -i -n -p -- bash
```

프롬프트가 `root@umbrel:/#` 형태로 바뀌면 host shell입니다. 그다음 위 **11번의 최신 업데이트 방법**으로 저장소와 스크립트를 최신 상태로 맞춘 뒤, AI가 추천한 복구 방식에 맞는 명령을 아래 3가지 중에서 고르세요.

**chainstate rebuild**

```bash
sudo bash scripts/m1s-start-bitcoin-chainstate-rebuild.sh
sudo bash scripts/m1s-check-bitcoin-recovery-status.sh
```

**reindex**

```bash
sudo bash scripts/m1s-start-bitcoin-reindex.sh
sudo bash scripts/m1s-check-bitcoin-recovery-status.sh
```

**full resync**

```bash
sudo bash scripts/m1s-start-bitcoin-full-resync.sh
sudo bash scripts/m1s-check-bitcoin-recovery-status.sh
```

### 12-3. SSH나 직접 연결한 터미널에서 복구 명령 실행하기 (고급)

ODROID M1S에 SSH로 접속할 수 있거나, 모니터와 키보드로 직접 로그인한 경우에는 아래 방식으로 진행해도 됩니다. 먼저 위 **11번의 최신 업데이트 방법**으로 저장소와 스크립트를 최신 상태로 맞춘 뒤, AI가 추천한 복구 방식에 맞는 명령을 아래 3가지 중에서 고르세요.

**chainstate rebuild**

```bash
sudo bash scripts/m1s-start-bitcoin-chainstate-rebuild.sh
sudo bash scripts/m1s-check-bitcoin-recovery-status.sh
```

**reindex**

```bash
sudo bash scripts/m1s-start-bitcoin-reindex.sh
sudo bash scripts/m1s-check-bitcoin-recovery-status.sh
```

**full resync**

```bash
sudo bash scripts/m1s-start-bitcoin-full-resync.sh
sudo bash scripts/m1s-check-bitcoin-recovery-status.sh
```

### 12-4. 헬스체크 출력 읽는 법

1번의 공용 헬스체크는 복구 명령을 고르기 전에는 현재 상태 판단용으로, 복구를 시작한 뒤에는 진행 상태 확인용으로 사용합니다.

리인덱스 중에는 특히 **Reindex blk file**, **Reindex file progress**, **Current status** 를 먼저 보면 됩니다.  
같은 명령을 몇 분 뒤 다시 실행했을 때 이 값들이 올라가면, 실제 리인덱스가 정상 진행 중이라는 뜻입니다.

실제 실행하면 이런 식으로 나옵니다.

```text
=== ODROID M1S Bitcoin recovery status ===
Script version:           0.5.5
Recovery mode:            reindex
Bitcoin config dir:       /mnt/fullnode/app-data/bitcoin/data/bitcoin
bitcoin.conf:             /mnt/fullnode/app-data/bitcoin/data/bitcoin/bitcoin.conf
umbrel-bitcoin.conf:      /mnt/fullnode/app-data/bitcoin/data/bitcoin/umbrel-bitcoin.conf
debug.log:                /mnt/fullnode/app-data/bitcoin/data/bitcoin/debug.log
State file:               /etc/umbrel-recovery/bitcoin-recovery.json
State file present:       1
Requested at:             2026-05-11T09:08:36.719946+00:00
Active request:           0
Last observed state:      recovery-in-progress
Include banner present:   0
Config reindex present:   0
Config chainstate present:0
Managed request block:    0
Log mode hint:            reindex
Runtime mode hint:        none
Recent startup evidence:  1
RPC getchainstates:       1
RPC getblockchaininfo:    1
Blocks / headers:         0 / 576166
Approx progress:          0.00%
Reindex blk file:         blk01743.dat / blk01799.dat
Reindex file progress:    96.89%
Last file load blocks:    250

Current status: recovery in progress

Recent Bitcoin error hints:
  2026-05-16T02:58:27Z [error] Fatal LevelDB error: IO error: /data/bitcoin/indexes/txindex/048611.ldb: Input/output error

=== System diagnostics ===
Uptime and load:
  19:42:10 up 3 days,  load average: 1.20, 1.05, 0.98

Memory usage:
  Mem:           7.6Gi       3.2Gi       1.1Gi       3.3Gi
  Swap:          4.0Gi       512Mi       3.5Gi

Active swap:
  NAME                    TYPE SIZE USED PRIO
  /mnt/fullnode/swapfile  file   4G 512M   -2

Docker service state:
  active
  active

Recent NVMe timeout snapshots:
  snapshot directory unavailable

=== Storage diagnostics ===
Data dir target:          /mnt/fullnode
Mount source:             /dev/nvme0n1p1
Mount filesystem:         ext4
Mount options:            rw,relatime
Parent block device:      /dev/nvme0n1

Disk space usage:
  Filesystem      Size  Used Avail Use% Mounted on
  /dev/nvme0n1p1  1.8T  870G  850G  51% /mnt/fullnode

Inode usage:
  Filesystem        Inodes IUsed     IFree IUse% Mounted on
  /dev/nvme0n1p1 122101760 98000 122003760    1% /mnt/fullnode

Block device summary:
  NAME        TYPE  SIZE FSTYPE MODEL           MOUNTPOINTS
  nvme0n1     disk  1.8T        Example NVMe
  └─nvme0n1p1 part  1.8T ext4                   /mnt/fullnode

Recent kernel storage hints:
  none visible in recent kernel logs, or kernel log access is restricted

Use this same command again later to watch the live progress estimate.
```

각 항목은 다음과 같습니다.

- Script version: 이 스크립트의 버전
- **Recovery mode**: 현재 감지된 복구 방식 (chainstate rebuild / reindex / full resync / unknown)
- Bitcoin config dir: Bitcoin Core 설정 파일이 있는 디렉터리 경로
- bitcoin.conf: Bitcoin Core 메인 설정 파일 경로
- umbrel-bitcoin.conf: Umbrel이 자동 생성한 Bitcoin 설정 파일 경로
- debug.log: Bitcoin Core 실행 로그 파일 경로
- State file present: 복구 요청 상태 파일이 존재하면 1, 없으면 0
- Requested at: 복구를 요청한 시각
- Active request: 아직 처리되지 않은 활성 복구 요청이 있으면 1, 없으면 0
- Last observed state: 마지막으로 기록된 복구 상태
- Config reindex present: 설정 파일에 reindex=1이 있으면 1
- Config chainstate present: 설정 파일에 reindex-chainstate=1이 있으면 1
- Log mode hint: debug.log에서 추론한 복구 모드
- Runtime mode hint: 실시간 RPC 값으로 추론한 복구 모드
- Recent startup evidence: 요청 이후 Bitcoin이 실제로 재시작된 로그 증거가 있으면 1
- RPC getchainstates: bitcoin-cli getchainstates 호출 성공 여부
- RPC getblockchaininfo: bitcoin-cli getblockchaininfo 호출 성공 여부
- **Blocks / headers**: 현재 동기화된 블록 수 / 전체 알려진 헤더 수
- **Approx progress**: 블록 동기화 대략적인 진행률. 다만 reindex 중에는 이 값이 오래 `0.00%`처럼 보일 수 있으므로, 그럴 때는 **Reindex blk file** 과 **Reindex file progress** 를 함께 보는 것이 더 정확합니다.
- Reindex blk file: 현재 다시 읽는 `blkXXXXX.dat` 파일 / 디스크에 있는 마지막 `blkXXXXX.dat` 파일
- Reindex file progress: 리인덱스가 block 파일 기준으로 어디까지 왔는지 보여주는 대략적인 진행률입니다. 이 값이 시간이 지나면서 올라가면 리인덱스가 실제로 앞으로 진행 중이라는 뜻입니다.
- Last file load blocks: 가장 최근 `blkXXXXX.dat` 파일에서 읽은 블록 수
- **Current status**: 현재 복구 상태를 사람이 읽을 수 있는 문장으로 요약
- **Recent Bitcoin error hints**: `debug.log` 끝부분에서 LevelDB, txindex, chainstate, Fatal, I/O error 같은 최근 오류 줄만 추려 보여 줍니다.
- **System diagnostics**: 부하, 메모리, swap, Docker 서비스 상태, 기존 NVMe timeout snapshot 존재 여부를 보여 줘서 리소스 압박이나 Docker 문제를 함께 판단할 수 있게 합니다.
- **Storage diagnostics**: `/mnt/fullnode`가 어떤 장치에 마운트되어 있는지, 디스크/아이노드 여유가 있는지, 블록 장치가 무엇인지, 가능한 경우 NVMe/SMART 상태와 커널 저장장치 힌트를 함께 보여 줍니다.
- **Recent kernel storage hints**: 여기에 NVMe timeout / reset / I/O error / EXT4 error가 보이면 Bitcoin 인덱스만의 문제가 아니라 SSD/NVMe/파일시스템 문제일 수 있으므로, 출력 전체를 복사해서 확인해야 합니다.

---

## 13. 안전하게 종료하기

ODROID M1S를 끌 때는 **전원 케이블을 바로 뽑지 마세요.**

Bitcoin 노드가 실행 중일 때 전원을 갑자기 끄면, SSD 안의 Bitcoin 데이터가 손상될 수 있습니다. 그러면 다음 부팅 때 Bitcoin 앱이 오래 복구 작업을 하거나, 다시 동기화해야 할 수 있습니다.

종료할 때는 Umbrel 웹 화면에서 아래 순서로 진행합니다.

```text
Settings → Shut down
```

한국어 화면에서는 아래처럼 보일 수 있습니다.

```text
설정 → 종료
```

종료 버튼을 누르면 이 설치 스크립트가 적용한 안전 종료 설정 때문에 Bitcoin 노드 앱과 Umbrel 컨테이너가 먼저 정리되고, Docker가 바로 다시 켜지지 않도록 바뀝니다. 정상적으로 완료되면 화면이 아래 문구로 바뀝니다.

```text
종료 완료
이제 디바이스 전원을 분리해도 좋습니다.
```

이 문구가 보이면 장비 전원 자체가 꺼져 있지 않아도 전원 케이블을 분리해도 됩니다.

만약 2분 이상 지나도 화면이 계속 **“종료 중...”** 으로만 남아 있으면, 새 탭에서 아래 주소를 다시 열어 보세요.

```text
http://umbrel.local
```

새로 연 탭에서 Umbrel 화면이 열리지 않으면, Umbrel 컨테이너가 멈춘 상태입니다. 이 경우에도 전원 케이블을 분리해도 됩니다.

다시 사용할 때는 전원 케이블을 연결하세요. 부팅 중 자동 복구 서비스가 Umbrel의 자동 시작 설정을 되돌리고 Umbrel을 다시 시작합니다.

---

## 14. 커널 재시작이 필요한 업데이트하기

가끔 Ubuntu 보안 업데이트나 커널 업데이트처럼 **재부팅해야 완전히 적용되는 업데이트**가 있습니다.

이 작업은 Umbrel 앱 데이터나 Bitcoin 노드 데이터를 지우는 작업이 아닙니다. 대신 업데이트와 재부팅 중에는 Umbrel 웹 화면과 Bitcoin 노드가 잠시 멈춥니다.

그래서 이 저장소에는 한 줄로 실행할 수 있는 전용 스크립트가 들어 있습니다. 이 스크립트는 다음 순서로 동작합니다.

1. Ubuntu 패키지 목록을 최신 상태로 가져옵니다.
2. 실행 중인 Docker 컨테이너를 확인합니다.
3. Bitcoin 관련 컨테이너가 있으면 안내를 보여 줍니다.
4. 실행 중인 Docker 컨테이너를 안전하게 멈춥니다.
5. Ubuntu 패키지 업데이트를 적용합니다.
6. 재부팅이 필요하면 자동으로 재부팅합니다.
7. 재부팅이 필요 없으면 멈췄던 컨테이너를 다시 시작합니다.

Bitcoin 노드가 IBD(초기 블록 다운로드), 블록 다운로드, 리인덱스, 복구 작업을 하는 중이라면 이 스크립트가 컨테이너를 안전하게 멈추기는 하지만, 작업 자체는 중간에 끊깁니다. 가능하면 그런 작업이 한창 진행 중이 아닐 때 실행하세요.

### 14-1. Umbrel 웹 화면 안의 고급 설정 터미널에서 하는 방법 (추천)

이미 Umbrel 웹 화면에 접속할 수 있다면, 웹 화면 안의 Terminal에서 진행하는 방법이 가장 쉽습니다.

순서는 다음과 같습니다.

1. Umbrel 웹 화면에 로그인합니다.
2. **Settings → Advanced settings → Terminal** 로 이동합니다. 한국어 화면에서는 **설정 → 고급 설정 → 터미널** 로 보일 수 있습니다.
3. 터미널이 열리면 먼저 아래 명령으로 호스트 쉘에 들어갑니다.

```bash
sudo nsenter -t 1 -m -u -i -n -p -- bash
```

프롬프트가 `root@umbrel:/#` 형태로 바뀌면 아래 명령을 차례대로 입력합니다.

```bash
cd /home/*/odroid-m1s-umbrel-recovery
sudo git -c safe.directory="$(pwd)" fetch https://github.com/dongguri-jun/odroid-m1s-umbrel-recovery.git main
sudo git -c safe.directory="$(pwd)" reset --hard FETCH_HEAD
sudo bash scripts/m1s-update-system-packages.sh
```

스크립트가 재부팅을 실행하면 웹 터미널 연결이 끊기는 것이 정상입니다. 장비가 다시 켜질 때까지 1~3분 정도 기다린 뒤 `http://umbrel.local` 또는 장비 IP 주소로 다시 접속하세요.

### 14-2. SSH나 직접 연결한 터미널에서 하는 방법 (고급)

ODROID M1S에 SSH로 접속할 수 있거나, 모니터와 키보드로 직접 로그인한 경우에는 아래 명령을 위에서부터 차례로 입력해도 됩니다.

```bash
cd /home/*/odroid-m1s-umbrel-recovery
sudo git -c safe.directory="$(pwd)" fetch https://github.com/dongguri-jun/odroid-m1s-umbrel-recovery.git main
sudo git -c safe.directory="$(pwd)" reset --hard FETCH_HEAD
sudo bash scripts/m1s-update-system-packages.sh
```

각 줄이 하는 일:

1. `cd /home/*/odroid-m1s-umbrel-recovery` — 처음 설치할 때 받아 둔 저장소 폴더로 이동합니다.
2. `sudo git -c safe.directory="$(pwd)" fetch https://github.com/dongguri-jun/odroid-m1s-umbrel-recovery.git main` — 장비에 저장된 `origin` 설정을 믿지 않고, 공식 GitHub 저장소에서 최신 변경 내역을 직접 가져옵니다.
3. `sudo git -c safe.directory="$(pwd)" reset --hard FETCH_HEAD` — 방금 공식 저장소에서 가져온 최신 파일 상태와 로컬 파일을 똑같이 맞춥니다.
4. `sudo bash scripts/m1s-update-system-packages.sh` — Docker 컨테이너를 안전하게 멈춘 뒤 Ubuntu 패키지 업데이트를 적용하고, 필요하면 자동으로 재부팅합니다.

재부팅이 실행되면 SSH 연결이 끊기는 것이 정상입니다. 1~3분 정도 기다린 뒤 브라우저에서 다시 아래 주소를 열어 보세요.

```text
http://umbrel.local
```

`umbrel.local`이 열리지 않으면 Fing 앱이나 공유기 화면에서 ODROID M1S의 IP 주소를 확인한 뒤 `http://<장비 IP>`로 접속하면 됩니다.

주의할 점은 다음과 같습니다.

- 재부팅 중에는 Umbrel 웹 화면이 열리지 않습니다. 잠시 기다린 뒤 다시 접속하세요.
- Bitcoin 노드가 IBD, 다운로드, 복구, 리인덱스를 진행 중이라면, 가능하면 작업이 안정된 뒤 실행하는 것이 좋습니다.
- 이 절차는 Ubuntu 패키지를 업데이트하는 절차입니다. 11번의 저장소 스크립트 업데이트와는 역할이 다르므로, 둘 다 필요할 수 있습니다.

---

## 15. 공식 umbrelOS / Umbrel Home과 다른 점

이 설치 방법은 ODROID M1S에 공식 umbrelOS 이미지를 직접 설치하는 방식이 아닙니다.

기존 Ubuntu 환경 위에 Docker를 설치하고, 그 위에서 Umbrel 컨테이너를 실행하는 방식입니다. 이 스크립트는 [`dockurr/umbrel`](https://hub.docker.com/r/dockurr/umbrel) Docker 이미지를 사용합니다. 이 이미지는 “umbrelOS inside a Docker container”를 목표로 하지만, 공식 umbrelOS 전체를 ODROID M1S에 직접 설치하는 방식은 아닙니다.

따라서 Umbrel Web UI, App Store, 앱 실행, 기본 Files 기능은 사용할 수 있지만, 공식 Umbrel Home 기기나 공식 umbrelOS 이미지와 완전히 동일하게 동작하지 않는 기능이 있습니다.

이 설치 방식에서 확인된 주요 지원 범위는 다음과 같습니다.

- Umbrel Web UI 접속
- App Store 사용
- 앱 설치, 실행, 삭제
- Docker 기반 앱 컨테이너 관리
- `/mnt/fullnode` 기반 앱 데이터 저장 (`/data`는 Umbrel Files 호환을 위한 같은 위치의 별칭으로 사용)
- Files의 기본 폴더와 앱 데이터 폴더 사용
- 홈 화면 Shortcuts
- Files 내장 텍스트 에디터
- `umbrel.local` 접속
- 재부팅 후 Umbrel 자동 시작

다음 기능은 공식 Umbrel Home / 공식 umbrelOS와 동일하게 지원되지 않을 수 있습니다.

### 15-1. Umbrel UI를 통한 OS / 커널 업데이트

Umbrel 컨테이너를 업데이트해도 ODROID M1S의 Ubuntu 커널이 함께 업데이트되지는 않습니다.

커널 보안 패치, Ubuntu 패키지 업데이트, 재부팅 필요 여부 확인은 별도의 Ubuntu 시스템 업데이트 절차로 관리해야 합니다. 이 저장소에서는 `scripts/m1s-update-system-packages.sh` 스크립트로 Ubuntu 패키지 업데이트를 별도로 진행합니다.

Umbrel UI의 OS 업데이트 버튼은 이 Dockur 기반 설치 방식에서 지원되지 않습니다. Umbrel 업데이트는 11번의 저장소 updater 절차를 사용하세요.

### 15-2. Umbrel UI를 통한 외장 USB 디스크 관리

공식 umbrelOS처럼 Umbrel UI에서 외장 USB 디스크를 자동 감지하거나, 포맷하거나, 마운트/해제하는 기능은 이 설치 방식에서 동일하게 보장되지 않습니다.

외장 USB 저장장치를 사용하려면 Ubuntu 호스트에서 별도로 마운트해야 할 수 있습니다.

### 15-3. Umbrel UI를 통한 NAS / SMB / NFS 네트워크 드라이브 연결

공식 umbrelOS의 네트워크 드라이브 연결 기능이 이 Docker 기반 설치 방식에서 동일하게 동작한다고 보장할 수 없습니다.

NAS, SMB, NFS 공유를 사용하려면 Ubuntu 호스트에서 별도로 마운트해야 할 수 있습니다.

### 15-4. Umbrel Settings의 네트워크 파일 공유

공식 Umbrel Home처럼 Umbrel Settings에서 공유 폴더를 켜고 끄는 방식의 네트워크 파일 공유는 이 설치 방식에서 지원되지 않을 수 있습니다.

Samba 공유가 필요하다면 Ubuntu 호스트에서 별도로 설정해야 합니다.

### 15-5. Umbrel UI를 통한 DNS / 고정 IP 설정

ODROID M1S의 실제 네트워크 설정은 Ubuntu 호스트가 관리합니다.

따라서 DNS, 고정 IP 설정은 Umbrel UI가 아니라 공유기 설정 또는 Ubuntu 네트워크 설정에서 관리하는 것을 권장합니다. 호스트 이름은 `umbrel.local` 접속을 위해 `umbrel`로 유지됩니다.

### 15-6. Ubuntu 호스트 전체 파일시스템 접근

Umbrel Files는 기본적으로 Umbrel 데이터 디렉터리인 `/mnt/fullnode` 기반 경로만 사용합니다.

보안상 Ubuntu 호스트의 `/etc`, `/boot`, `/home`, `/var` 같은 전체 파일시스템을 Umbrel 컨테이너에 노출하지 않습니다.

요약하면, 이 설치 방식은 ODROID M1S에서 Umbrel 앱 환경을 안정적으로 실행하기 위한 Docker 기반 설치 방식입니다. 공식 Umbrel Home과 비슷하게 앱과 기본 파일 기능을 사용할 수 있지만, OS 전체를 Umbrel이 직접 제어하는 공식 umbrelOS와는 구조가 다릅니다. 외장 스토리지, 네트워크 공유, 커널 업데이트, 고정 IP 같은 호스트 OS 수준의 기능은 Ubuntu에서 별도로 관리해야 합니다.

---

## 16. 더 자세한 자료

설치를 마친 뒤 더 알아보고 싶은 내용이 있다면 아래 자료를 참고하세요.

- **ODROID M1S 공식 위키 (Hardkernel)** — https://wiki.odroid.com/odroid-m1s/odroid-m1s
  - 하드웨어 사양, 부팅, Ubuntu 설치 등 ODROID M1S 자체에 대한 공식 자료입니다.
- **Umbrel OS 사용 가이드 (PDF, 한국어)** — https://philemon21.com/wp-content/uploads/2026/01/3.-%ED%92%80-%EB%85%B8%EB%93%9C-%EC%9A%B4%EC%98%81-%EA%B0%80%EC%9D%B4%EB%93%9C-v.2.1-2025.-9.-1.pdf
  - 설치 후 Umbrel을 운영하는 데 참고할 수 있는 한국어 가이드입니다.
