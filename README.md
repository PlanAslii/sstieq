# SSH-VPN Panel v1.0.0

پنل پیشرفته مدیریت SSH VPN با پشتیبانی از Dropbear، Stunnel SSL، Squid Proxy و BadVPN UDPGW.

طراحی شده برای استفاده با Injectorهای اندروید (مثل HTTP Injector، KPN Tunnel و غیره).

## ویژگی‌ها

- **نصب‌کننده خودکار** با یک دستور
- **آپدیت خودکار** از GitHub
- **مدیریت کاربر**: ساخت، حذف، تمدید، لیست
- **دیتابیس SQLite** برای کاربران، اتصالات و تنظیمات
- **نمایش کاربران آنلاین** و تعداد اتصالات
- **مصرف ترافیک** (با vnstat + لاگ اتصالات)
- **پورت‌های چندگانه**:
  - Dropbear: `143, 444, 666, 5555, 701, 179`
  - Dropbear SSL (Stunnel): `110, 443, 587`
  - Squid Proxy: `8080, 8000, 3128`
  - BadVPN UDPGW: `7300`
- **BBR** فعال برای سرعت بالاتر
- **پیام موفقیت شیک** از طریق Cloudflare Worker (قابل تغییر)
- **لاگ‌های واضح** خطا و موفقیت
- **چک انقضای خودکار** هر ۶ ساعت
- **فایروال UFW** پیکربندی‌شده

## پیش‌نیاز

- Ubuntu 20.04 / 22.04 یا Debian 11+
- دسترسی root
- حداقل ۱ گیگ رم و ۱۰ گیگ هارد

## نصب

```bash
# دانلود و اجرا
git clone https://github.com/YOUR_USERNAME/ssh-vpn-panel.git
cd ssh-vpn-panel
chmod +x install.sh
./install.sh
```

یا به صورت مستقیم:

```bash
wget -O install.sh https://raw.githubusercontent.com/YOUR_USERNAME/ssh-vpn-panel/main/install.sh
chmod +x install.sh
./install.sh
```

پس از نصب دستور زیر را بزنید:

```bash
sshvpn
```

## منوی پنل

| گزینه | توضیح |
|-------|-------|
| 1 | ایجاد کاربر جدید (با خروجی شبیه سایت‌های SSH) |
| 2 | حذف کاربر |
| 3 | لیست کاربران + وضعیت انقضا |
| 4 | کاربران آنلاین و تعداد اتصالات |
| 5 | مصرف ترافیک کاربر |
| 6 | تنظیم آدرس Worker موفقیت |
| 7 | بررسی و نصب آپدیت از GitHub |
| 8 | اطلاعات سیستم و وضعیت سرویس‌ها |
| 9 | ریستارت تمام سرویس‌ها |
| 10 | تمدید کاربر |

## پیام موفقیت (Worker)

1. فایل `worker/success-worker.js` را در Cloudflare Workers بسازید.
2. آدرس Worker را کپی کنید (مثلاً `https://ssh-success.yourname.workers.dev`).
3. در منوی پنل گزینه **۶** را انتخاب و آدرس را وارد کنید.
4. هر بار که بخواهید پیام را تغییر دهید، فقط Worker را ادیت کنید. بنر Dropbear خودکار آپدیت می‌شود.

مثال پیام موفقیت در لاگ کلاینت:

```
✨ اتصال موفقیت‌آمیز بود! ✨
🚀 SSH-VPN Panel - High Speed Connection
از سرعت و پایداری لذت ببرید.
```

## آپدیت خودکار

- هر شب ساعت ۳ صبح از GitHub چک می‌کند.
- یا دستی از منوی گزینه ۷.
- ابتدا در تنظیمات (یا دیتابیس) ریپوی خود را ست کنید: `username/repo`

## ساختار پروژه

```
ssh-vpn-panel/
├── install.sh              # نصب‌کننده اصلی
├── VERSION
├── README.md
├── config/
│   └── banner.txt          # بنر خوش‌آمدگویی Dropbear
├── scripts/
│   ├── menu.sh             # منوی اصلی (دستور sshvpn)
│   ├── check_expire.sh     # کرون چک انقضا
│   └── auto_update.sh      # آپدیت از GitHub
├── worker/
│   └── success-worker.js   # مثال Cloudflare Worker
├── db/                     # (ساخته می‌شود در /etc)
└── logs/                   # (ساخته می‌شود در /etc)
```

## نکات مهم برای Injector

- پورت اصلی پیشنهادی: **143**
- نوع تانل: **SSH (Direct)** یا **SSH + SSL** (پورت 443)
- برای UDP: از BadVPN 7300 استفاده کنید (در تنظیمات injector)
- Compression را روشن بگذارید تا سرعت بهتر شود.

## عیب‌یابی

| مشکل | راه‌حل |
|------|--------|
| Cannot authenticate | نام کاربری یا رمز اشتباه / کاربر منقضی شده |
| Connection refused | فایروال یا سرویس dropbear خاموش است → گزینه ۸ و ۹ |
| سرعت پایین | BBR را چک کنید (`sysctl net.ipv4.tcp_congestion_control`) |
| بنر موفقیت نمی‌آید | آدرس Worker را درست وارد کرده باشید |

لاگ‌ها در مسیر:

```
/etc/ssh-vpn-panel/logs/panel.log
/etc/ssh-vpn-panel/logs/auth.log
/etc/ssh-vpn-panel/logs/expire.log
/etc/ssh-vpn-panel/logs/update.log
```

## لایسنس

MIT - آزاد برای استفاده و تغییر.

---
ساخته شده با ❤️ برای جامعه SSH Tunnel
