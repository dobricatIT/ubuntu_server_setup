#!/bin/bash

# Функция для отображения цветного прогресс-бара
show_progress() {
    local progress=$1
    local width=50  # ширина прогресс-бара
    local fill=$((progress * width / 100))
    local empty=$((width - fill))

    local color_reset="\e[0m"
    local color_fill="\e[42m"  # зеленый фон
    local color_empty="\e[41m"  # красный фон

    printf "\r["
    printf "${color_fill}%*s${color_reset}" "$fill" ""
    printf "${color_empty}%*s${color_reset}" "$empty" ""
    printf "] %d%%" "$progress"
}

validate_username() {
    local username=$1
    if [[ "$username" =~ ^[a-zA-Z0-9_]+$ ]]; then
        return 0
    else
        echo "Неверное имя пользователя. Оно должно содержать только буквы, цифры и подчеркивания."
        return 1
    fi
}

check_logs() {
    if ! ls /var/log/*.log 1> /dev/null 2>&1 || ! grep -q 'auth.log' /var/log/*.log; then
        return 1
    fi
    return 0
}

echo "Обновление и установка пакетов..."
show_progress 20
apt-get update -y >/dev/null 2>&1
show_progress 30
apt-get upgrade -y >/dev/null 2>&1
show_progress 50
apt-get install -y sudo >/dev/null 2>&1
show_progress 70
apt-get install -y ufw fail2ban >/dev/null 2>&1
show_progress 90
show_progress 100
echo -e "\nНастройка завершена!"

if ! check_logs; then
    echo -e "\nЛоги не найдены. Устанавливаем rsyslog..."
    apt-get install -y rsyslog >/dev/null 2>&1
    systemctl restart rsyslog
    echo -e "\nRsyslog установлен и перезапущен."
else
    echo -e "\nЛоги найдены, продолжаем настройку Fail2Ban."
fi

read -p "Хотите создать нового пользователя для входа в систему вместо root? (да/нет): " create_new_user
create_new_user=$(echo "$create_new_user" | tr '[:upper:]' '[:lower:]' | tr -s ' ')

if [[ "$create_new_user" =~ ^(да|y|yes)$ ]]; then
    while true; do
        read -p "Введите имя нового пользователя (без пробелов и специальных символов): " username
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
    echo -e "\nПользователь $username успешно создан и добавлен в группу sudo."

    # Вопрос о настройке входа только по SSH
    read -p "Хотите разрешить вход только по SSH для пользователя $username? (да/нет): " ssh_only
    ssh_only=$(echo "$ssh_only" | tr '[:upper:]' '[:lower:]' | tr -s ' ')

    if [[ "$ssh_only" =~ ^(да|y|yes)$ ]]; then
        # SSH Key Setup
        echo -e "\nНастройка входа по SSH ключу для пользователя $username."
        mkdir -p "/home/$username/.ssh"
        chmod 700 "/home/$username/.ssh"

        read -p "Введите ваш публичный SSH ключ: " ssh_key

        if [[ "$ssh_key" =~ ^ssh-(rsa|ed25519) ]]; then
            echo "$ssh_key" > "/home/$username/.ssh/authorized_keys"
            chmod 600 "/home/$username/.ssh/authorized_keys"
            chown -R "$username:$username" "/home/$username/.ssh"
            echo -e "\nSSH ключ успешно настроен для пользователя $username."

            # Запрет входа по паролю
            sed -i "/^#*PasswordAuthentication/s/^#*.*/PasswordAuthentication no/" /etc/ssh/sshd_config
            systemctl restart ssh
            echo -e "\nВход по паролю отключен, разрешен только вход по SSH ключу."
        else
            echo "Неверный формат SSH ключа. Настройка не выполнена."
        fi
    else
        echo -e "\nНастройка входа только по SSH пропущена."
    fi
else
    echo -e "\nОставляем root-пользователя для входа в систему."
fi

while true; do
    echo "Для повышения безопасности сервера рекомендуется изменить стандартный порт SSH."
    read -p "Введите новый порт SSH (рекомендуется диапазон от 1024 до 65535): " ssh_port
    if [[ "$ssh_port" =~ ^[0-9]+$ ]] && ((ssh_port >= 1024 && ssh_port <= 65535)); then
        break
    else
        echo "Пожалуйста, введите корректный порт в диапазоне от 1024 до 65535."
    fi

done

sed -i "s/^#Port 22/Port $ssh_port/" /etc/ssh/sshd_config
systemctl restart ssh
echo -e "\nПорт SSH успешно изменен на $ssh_port."

echo "Настройка фаервола (ufw)..."
ufw allow "$ssh_port"/tcp >/dev/null 2>&1
show_progress 20
ufw allow http >/dev/null 2>&1
ufw allow https >/dev/null 2>&1
show_progress 50
ufw default deny incoming >/dev/null 2>&1
ufw default allow outgoing >/dev/null 2>&1
show_progress 70
ufw --force enable >/dev/null 2>&1
show_progress 100
echo -e "\nФаервол успешно настроен!"

read -p "Хотите запретить вход по SSH для root-пользователя? (да/нет): " disable_root_ssh
if [[ "$disable_root_ssh" =~ ^(да|y|yes)$ ]]; then
    sed -i '/^#*PermitRootLogin/s/^#*.*/PermitRootLogin no/' /etc/ssh/sshd_config
    systemctl restart ssh
    echo -e "\nВход по SSH для root-пользователя успешно запрещен."
else
    echo -e "\nВход по SSH для root-пользователя оставлен включенным."
fi

read -p "Хотите установить защиту от брутфорса с помощью fail2ban? (да/нет): " install_fail2ban
if [[ "$install_fail2ban" =~ ^(да|y|yes)$ ]]; then
    echo -e "\nНастройка fail2ban..."
    read -p "Введите количество неудачных попыток входа до блокировки: " max_attempts
    read -p "Введите время блокировки в секундах: " bantime
    read -p "Введите временной интервал (в секундах) для подсчета попыток: " findtime

    cat <<EOL > /etc/fail2ban/jail.d/ssh.local
[sshd]
enabled = true
port    = $ssh_port
logpath = /var/log/auth.log
maxretry = $max_attempts
bantime = $bantime
findtime = $findtime
EOL

    systemctl restart fail2ban
    echo -e "\nЗащита от брутфорса с помощью fail2ban настроена и активирована."
else
    echo -e "\nЗащита от брутфорса с помощью fail2ban не будет установлена."
fi