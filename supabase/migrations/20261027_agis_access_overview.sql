-- Sist innlogget for personer på tilgangslistene, kun for ansatte (til tilgangsoversikten i AGIS).
create or replace function public.kart_user_logins(p_emails text[])
returns table(email text, last_sign_in_at timestamptz)
language sql stable security definer set search_path = public, auth as $$
  select lower(u.email)::text, u.last_sign_in_at
  from auth.users u
  where public.kart_is_staff() and lower(u.email) = any (select lower(x) from unnest(p_emails) x);
$$;
revoke all on function public.kart_user_logins(text[]) from public, anon;
grant execute on function public.kart_user_logins(text[]) to authenticated;
