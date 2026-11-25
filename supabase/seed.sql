-- Starting data: settings + the Chefpy team (sample people; replace with real staff in the Team screen)
insert into public.hrms_settings(id) values (1) on conflict (id) do nothing;
insert into public.hrms_employees(id,name,role,dept,title,salary,mgr,phone,bank,pw_hash) values
 ('E01','Ananya Rao','admin','Management','Operations Head',90000,null,'98450 11201','HDFC Bank ••4521',extensions.crypt('admin123',extensions.gen_salt('bf'))),
 ('E02','Kavya Menon','hr','HR','HR Manager',55000,null,'98450 11202','ICICI Bank ••0917',extensions.crypt('hr123',extensions.gen_salt('bf'))),
 ('E03','Rohit Sharma','manager','Sales','Sales Manager',60000,null,'98450 11203','Axis Bank ••3310',extensions.crypt('sales123',extensions.gen_salt('bf')))
on conflict (id) do nothing;
insert into public.hrms_employees(id,name,role,dept,title,salary,mgr,phone,bank,pw_hash) values
 ('E04','Priya Nair','sales','Sales','Sales Executive',28000,'E03','98450 11204','UPI priya.nair@okhdfc',extensions.crypt('emp123',extensions.gen_salt('bf'))),
 ('E05','Arjun Patil','sales','Sales','Sales Executive',26000,'E03','98450 11205','SBI ••8842',extensions.crypt('emp123',extensions.gen_salt('bf'))),
 ('E06','Sneha Kulkarni','sales','Sales','Senior Sales Executive',32000,'E03','98450 11206','Kotak ••1206',extensions.crypt('emp123',extensions.gen_salt('bf'))),
 ('E07','Vikram Joshi','sales','Sales','Sales Executive',25000,'E03','98450 11207','UPI vikramj@ybl',extensions.crypt('emp123',extensions.gen_salt('bf'))),
 ('E08','Meera Iyer','sales','Sales','Sales Executive',27000,'E03','98450 11208','HDFC Bank ••5570',extensions.crypt('emp123',extensions.gen_salt('bf'))),
 ('E09','Farhan Shaikh','ops','Chef Operations','Chef Coordinator',32000,'E01','98450 11209','SBI ••4418',extensions.crypt('emp123',extensions.gen_salt('bf'))),
 ('E10','Divya Reddy','ops','Chef Operations','Booking Coordinator',30000,'E01','98450 11210','UPI divya.r@oksbi',extensions.crypt('emp123',extensions.gen_salt('bf')))
on conflict (id) do nothing;
insert into public.hrms_targets(emp,calls,talk,conv,rev) values
 ('E04',900,2400,24,450000),('E05',900,2400,22,400000),('E06',1000,2700,30,550000),('E07',850,2200,20,350000),('E08',900,2400,24,420000)
on conflict (emp) do nothing;
