/**
 * Cloudflare Worker مثال برای پیام موفقیت اتصال
 * 
 * نحوه استفاده:
 * 1. این کد را در Cloudflare Workers بسازید
 * 2. آدرس Worker را در منوی پنل (گزینه ۶) وارد کنید
 * 3. هر بار که کاربر با موفقیت وصل شود، بنر Dropbear از این آدرس آپدیت می‌شود
 * 
 * می‌توانید پیام را هر طور دوست دارید تغییر دهید.
 */

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    
    // می‌توانید بر اساس پارامترها پیام‌های مختلف بدهید
    // مثلاً ?lang=fa یا ?user=xxx

    const message = `
╔══════════════════════════════════════════════════════╗
║                                                      ║
║          ✨ اتصال موفقیت‌آمیز بود! ✨                 ║
║                                                      ║
║     🚀 SSH-VPN Panel - High Speed Connection         ║
║                                                      ║
║   از سرعت و پایداری لذت ببرید.                       ║
║   Enjoy your high-speed secure connection.           ║
║                                                      ║
║   Support: @YourTelegram | GitHub Updates            ║
║                                                      ║
╚══════════════════════════════════════════════════════╝
`;

    return new Response(message.trim(), {
      headers: {
        'Content-Type': 'text/plain; charset=utf-8',
        'Cache-Control': 'no-cache',
      },
    });
  },
};
