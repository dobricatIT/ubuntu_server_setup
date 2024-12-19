#!/bin/bash

# Функция для отображения цветного прогресс-бара
show_progress() {
    local progress=$1
    local width=50
    local fill=$((progress * width / 100))
    local empty=$((width - fill))

    # Цвета
    local color_reset="\e[0m"
    local color_fill="\e[42m"
    local color_empty="\e[41m"

    # Построение строки прогресс-бара
    printf "\r["
    printf "${color_fill}%*s${color_reset}" "$fill" ""
    printf "${color_empty}%*s${color_reset}" "$empty" ""
    printf "] %d%%" "$progress"
}

# Функция для проверки имени пользователя
validate_username() {
    local username=$1
    if [[ "$username" =~ ^[a-zA-Z0-9_]+$ ]]; then
        return 0
    else
        echo "Неверное имя пользователя. Оно должно содержать только буквы, цифры и подчеркивания."
        return 1
    fi
}

# Функция для проверки наличия логов
check_logs() {
    if ! ls /var/log/*.log 1> /dev/null 2>&1 || ! grep -q 'auth.log' /var/log/*.log; then
        return 1
    fi
    return 0
}

# Обновление и установка пакетов
show_progress 20
apt-get update -y >/dev/null 2>&1
show_progress 30
apt-get upgrade -y >/dev/null 2>&1
show_progress 50
apt-get install -y sudo ufw fail2ban >/dev/null 2>&1
show_progress 100
echo -e "\nНастройка завершена!"

# Проверка логов
if ! check_logs; then
    echo "Логи не найдены. Устанавливаем rsyslog..."
    apt-get install -y rsyslog >/dev/null 2>&1
    systemctl restart rsyslog
    echo "Rsyslog установлен и перезапущен."
else
    echo "Логи найдены."
fi

# Запрос на создание нового пользователя
read -p "Хотите создать нового пользователя вместо root? (да/нет): " create_new_user
create_new_user=$(echo "$create_new_user" | tr '[:upper:]' '[:lower:]' | tr -s ' ')

if [[ "$create_new_user" =~ ^(да|y|yes)$ ]]; then
    while true; do
        read -p "Введите имя нового пользователя: " username
        validate_username "$username" && break
    done

    while true; do
        read -s -p "Введите пароль для нового пользователя: " password
        echo
        read -s -p "Повторите пароль: " password_confirm
        echo
        if [[ "$password" == "$password_confirm" && -n "$password" ]]; then
            break
        else
            echo "Пароли не совпадают или пусты. Попробуйте снова."
        fi
    done

    useradd -m -s /bin/bash "$username"
    echo "$username:$password" | chpasswd
    usermod -aG sudo "$username"
    echo "Пользователь $username успешно создан."
fi

# Добавление SSH ключа
read -p "Хотите добавить SSH ключ для входа? (да/нет): " add_ssh_key
add_ssh_key=$(echo "$add_ssh_key" | tr '[:upper:]' '[:lower:]')

if [[ "$add_ssh_key" =~ ^(да|y|yes)$ ]]; then
    echo "Вставьте ваш публичный SSH ключ (одной строкой) и нажмите Enter:"
    read ssh_key
    if [[ "$create_new_user" =~ ^(да|y|yes)$ ]]; then
        mkdir -p "/home/$username/.ssh"
        echo "$ssh_key" >> "/home/$username/.ssh/authorized_keys"
        chmod 600 "/home/$username/.ssh/authorized_keys"
        chown -R "$username:$username" "/home/$username/.ssh"
        echo "SSH ключ добавлен для пользователя $username."
    else
        mkdir -p /root/.ssh
        echo "$ssh_key" >> /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
        echo "SSH ключ добавлен для пользователя root."
    fi

    read -p "Хотите отключить вход по паролю? (да/нет): " disable_password_login
    disable_password_login=$(echo "$disable_password_login" | tr '[:upper:]' '[:lower:]')

    if [[ "$disable_password_login" =~ ^(да|y|yes)$ ]]; then
        sed -i '/^#*PasswordAuthentication/s/^#*\(.*\)/PasswordAuthentication no/' /etc/ssh/sshd_config
        echo "Вход по паролю отключен."
    fi
    systemctl restart ssh
    echo "Служба SSH перезапущена."
fi

# Настройка порта SSH
while true; do
    echo "Введите новый порт SSH (1024-65535):"
    read ssh_port
    if [[ "$ssh_port" =~ ^[0-9]+$ ]] && ((ssh_port >= 1024 && ssh_port <= 65535)); then
        break
    else
        echo "Некорректный порт."
    fi

done
sed -i "s/^#Port 22/Port $ssh_port/" /etc/ssh/sshd_config
systemctl restart ssh
echo "Порт SSH изменён на $ssh_port."

# Настройка UFW
ufw allow "$ssh_port"/tcp >/dev/null 2>&1
ufw allow http >/dev/null 2>&1
ufw allow https >/dev/null 2>&1
ufw default deny incoming >/dev/null 2>&1
ufw default allow outgoing >/dev/null 2>&1
ufw --force enable >/dev/null 2>&1
echo "Фаервол настроен."

# Отключение root по SSH
read -p "Запретить вход по SSH для root? (да/нет): " disable_root_ssh
if [[ "$disable_root_ssh" =~ ^(да|y|yes)$ ]]; then
    sed -i '/^#*PermitRootLogin/s/^#*\(.*\)/PermitRootLogin no/' /etc/ssh/sshd_config
    systemctl restart ssh
    echo "Root доступ по SSH запрещён."
fi
