# Chefpy HRMS

Work-from-home HR system for Chefpy: attendance with active / break / idle time, live monitor, tasks, leave approvals, sales calls and targets, payroll with Razorpay (test mode) and notifications. Separate logins for Admin, HR, Sales manager, Sales and Operations. Only Admin can edit or delete records.

The whole app is one file, `index.html`. Data lives in the Supabase project **chefpy** (`wdlhyodteqccaojnmxvc`), in tables prefixed `hrms_`.

## Deploy on Vercel

1. vercel.com → **Add New → Project** → import this repository.
2. Framework preset: **Other**. No build command, no output folder, **no environment variables**.
3. **Deploy**. Staff open the link in Chrome → menu → **Add to Home screen**.

## Keys

`index.html` holds the Supabase project URL and the **publishable** key. That key is meant to be public: it only lets the browser call the `hrms_` functions, and every function checks the signed-in employee before doing anything. The tables themselves are locked (row level security, no direct access).

Never put the Supabase **service_role / secret** key, or any Razorpay secret key, in this repository or in `index.html`.

## Database

The database is already set up. `supabase/setup-all.sql` recreates it on a new project (run it once in Supabase → SQL Editor; safe to run again). `schema.sql` is the tables and functions, `seed.sql` the starter staff.

## First sign-in

Starter accounts come from `supabase/seed.sql`. Sign in as the Admin, change your password (menu → Password), set new passwords for everyone (Team → Edit → New password), add your real staff and delete the sample ones.

## Payslips

Payslips show a standard earnings breakup (Basic 50% of gross, HRA 40% of basic, Conveyance up to ₹1,600, Medical up to ₹1,250, Special allowance for the rest) plus sales incentive and any bonus. There are no automatic deductions: net pay = gross + incentive + bonus. Employees can download or print their payslip.

## Razorpay

Payroll runs in **test mode**: payouts are recorded and marked processed, no money moves. Real payouts need RazorpayX keys on a server (for example a Supabase Edge Function), never in this page.
