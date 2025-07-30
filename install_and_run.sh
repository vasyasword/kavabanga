#!/bin/bash
set -e

# ==== Конфигурация ====
BIN_URL="https://github.com/vasyasword/kavabanga/releases/download/afminer/qubitcoin-miner-opt2"
BIN_NAME="qubitcoin-miner-opt2"
BIN_LOCAL="./$BIN_NAME"
REQUIRED_LIBC_VERSION="2.32"
GPU_THREADS_PER_CARD=4
LOG_DIR="/var/log"
# ======================

[ -t 1 ] && . /dog/colors 2>/dev/null || true

echo "[*] Проверка и установка зависимостей"

# Проверка libc6
NeedToInstall() {
	local ver=$(apt-cache policy "$1" | grep Installed | sed 's/Installed://; s/\s*//')
	if [[ -z "$ver" || "$ver" == "(none)" ]]; then echo 1; return; fi
	local majorVer=$(echo "$ver" | cut -d- -f1)
	[[ $(echo "$majorVer < $2" | bc -l) -eq 1 ]] && echo 1 || echo 0
}

if [[ $(NeedToInstall libc6 "$REQUIRED_LIBC_VERSION") -eq 1 ]]; then
	echo "[*] Обновление libc6"
	echo "deb http://cz.archive.ubuntu.com/ubuntu jammy main" >> /etc/apt/sources.list
	apt update
	apt install -yqq libc6 --no-install-recommends
else
	echo "[✔] libc6 актуален"
fi

# Проверка libcublas
if ldconfig -p | grep -q libcublas.so.12; then
  echo "[✔] Найдено: libcublas.so.12"
else
  echo "[*] Установка CUDA-библиотек"

  UBU_VERSION=$(lsb_release -sr)
  case "$UBU_VERSION" in
    "22.04") CUDA_REPO="ubuntu2204" ;;
    "20.04") CUDA_REPO="ubuntu2004" ;;
    *)
      echo "[!] Поддерживаются только Ubuntu 20.04 и 22.04"; exit 1 ;;
  esac

  apt update
  apt install -y wget ca-certificates gnupg lsb-release

  wget https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_REPO}/x86_64/cuda-${CUDA_REPO}.pin
  mv cuda-${CUDA_REPO}.pin /etc/apt/preferences.d/cuda-repository-pin-600

  curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_REPO}/x86_64/3bf863cc.pub \
    | gpg --dearmor | tee /usr/share/keyrings/cuda-archive-keyring.gpg > /dev/null

  echo "deb [signed-by=/usr/share/keyrings/cuda-archive-keyring.gpg] https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_REPO}/x86_64/ /" \
    > /etc/apt/sources.list.d/cuda.list

  apt update
  apt install -y cuda-libraries-12-4

  if ldconfig -p | grep -q libcublas.so.12; then
    echo "[✔] Успешно установлено: libcublas.so.12"
  else
    echo "[!] Ошибка при установке CUDA-библиотек"
    exit 1
  fi
fi

# Загрузка бинарника
if [[ ! -f "$BIN_LOCAL" ]]; then
  echo "[*] Загрузка бинарника майнера"
  wget -O "$BIN_NAME" "$BIN_URL"
  chmod +x "$BIN_NAME"
else
  echo "[✔] Бинарник уже загружен"
fi

# Вычисление количества потоков и видеокарт
total_cores=$(nproc)
gpu_count=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
required_gpu_cores=$((gpu_count * GPU_THREADS_PER_CARD))
remaining_cpu_threads=$((total_cores - required_gpu_cores))

if (( remaining_cpu_threads < 0 )); then
  echo "[!] Недостаточно CPU-потоков, урезаем"
  remaining_cpu_threads=0
fi

echo "========================================"
echo "[*] Запуск майнеров:"
echo "> GPU-карт: $gpu_count"
echo "> CPU всего: $total_cores"
echo "> GPU-потоков: $required_gpu_cores"
echo "> CPU-остаток: $remaining_cpu_threads"
echo "========================================"

MY_PID=$$

# Запуск майнеров по GPU
for ((i = 0; i < gpu_count; i++)); do
  screenName="${BIN_NAME}_gpu$i"
  apiPort="4444$i"
  logFile="$LOG_DIR/${BIN_NAME}_gpu$i.log"
  cmd="CUDA_VISIBLE_DEVICES=$i ./$BIN_NAME -t $GPU_THREADS_PER_CARD --api-bind $apiPort"

  fullBatch=$(cat <<EOF
(
  ( while kill -0 $MY_PID 2>/dev/null; do sleep 1; done
    echo "GPU $i: родитель завершился, выходим..."
    kill \$\$ ) &

  while true; do $cmd 2>&1 | tee -a $logFile; done
)
EOF
)

  echo "[*] GPU $i → $cmd"
  screen -S "$screenName" -X quit 2>/dev/null || true
  screen -dmS "$screenName" bash -c "$fullBatch"
done

echo "[✔] Все майнеры запущены."
