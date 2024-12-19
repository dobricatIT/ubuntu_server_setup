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

# Добавление вопросов для root
echo -e "\nНастройка доступа для root пользователя."
read -p "Хотите добавить SSH ключ для root? (да/нет): " ssh_key_root
ssh_key_root=$(echo "$ssh_key_root" | tr '[:upper:]' '[:lower:]' | tr -s ' ')
if [[ "$ssh_key_root" =~ ^(да|y|yes)$ ]]; then
    mkdir -p "/root/.ssh"
    chmod 700 "/root/.ssh"

    read -p "Введите ваш публичный SSH ключ для root: " ssh_key
    if [[ "$ssh_key" =~ ^ssh-(rsa|ed25519) ]]; then
        echo "$ssh_key" > "/root/.ssh/authorized_keys"
        chmod 600 "/root/.ssh/authorized_keys"
        echo -e "\nSSH ключ успешно добавлен для root пользователя."
    else
        echo "Неверный формат SSH ключа. Настройка не выполнена."
    fi
fi

read -p "Хотите отключить вход по паролю для root? (да/нет): " disable_password_root
disable_password_root=$(echo "$disable_password_root" | tr '[:upper:]' '[:lower:]' | tr -s ' ')
if [[ "$disable_password_root" =~ ^(да|y|yes)$ ]]; then
    sed -i "/^#*PasswordAuthentication/s/^#*.*/PasswordAuthentication no/" /etc/ssh/sshd_config
    systemctl restart ssh
    echo -e "\nВход по паролю для root отключен."
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

    read -p "Хотите добавить SSH ключ для $username? (да/нет): " ssh_only
    ssh_only=$(echo "$ssh_only" | tr '[:upper:]' '[:lower:]' | tr -s ' ')
    if [[ "$ssh_only" =~ ^(да|y|yes)$ ]]; then
        mkdir -p "/home/$username/.ssh"
        chmod 700 "/home/$username/.ssh"

        read -p "Введите ваш публичный SSH ключ: " ssh_key
        if [[ "$ssh_key" =~ ^ssh-(rsa|ed25519) ]]; then
            echo "$ssh_key" > "/home/$username/.ssh/authorized_keys"
            chmod 600 "/home/$username/.ssh/authorized_keys"
            chown -R "$username:$username" "/home/$username/.ssh"
            echo -e "\nSSH ключ успешно настроен для пользователя $username."
        else
            echo "Неверный формат SSH ключа. Настройка не выполнена."
        fi
    fi

    read -p "Хотите отключить вход по паролю для $username? (да/нет): " disable_password_user
    disable_password_user=$(echo "$disable_password_user" | tr '[:upper:]' '[:lower:]' | tr -s ' ')
    if [[ "$disable_password_user" =~ ^(да|y|yes)$ ]]; then
        sed -i "/^#*PasswordAuthentication/s/^#*.*/PasswordAuthentication no/" /etc/ssh/sshd_config
        systemctl restart ssh
        echo -e "\nВход по паролю для $username отключен."
    fi
fi

echo -e "\nДля повышения безопасности рекомендуется изменить порт SSH."
read -p "Введите новый порт SSH (рекомендуется диапазон от 1024 до 65535): " ssh_port
if [[ "$ssh_port" =~ ^[0-9]+$ ]] && ((ssh_port >= 1024 && ssh_port <= 65535)); then
    sed -i "s/^#Port 22/Port $ssh_port/" /etc/ssh/sshd_config
    systemctl restart ssh
    echo -e "\nПорт SSH успешно изменен на $ssh_port."
else
    echo "Некорректный порт. Настройка пропущена."
fi
