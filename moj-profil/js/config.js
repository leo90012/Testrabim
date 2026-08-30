// ============================================================
//  Rabimbox – konfiguracija
// ============================================================
// Tukaj vpiši svoja Supabase podatka. URL je že vpisan.
// ANON (public) ključ najdeš v Supabase:
//   Dashboard -> Project Settings -> API Keys -> Legacy anon, service_role
//   -> kopiraj vrednost "anon public" (dolg niz, ki se začne z "eyJ...")
//
// OPOZORILO: sem NIKOLI ne vpisuj "service_role" ključa!
//            anon/publishable ključ je varno objaviti v brskalniku,
//            saj ga varujejo RLS pravila (glej sql/setup.sql).
// ============================================================

window.RABIMBOX_CONFIG = {
  SUPABASE_URL: "https://lvfnumhirarpshpqyoay.supabase.co",
  SUPABASE_ANON_KEY: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imx2Zm51bWhpcmFycHNocHF5b2F5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODM0NDA3NjAsImV4cCI6MjA5OTAxNjc2MH0.X-0kCvYo9aje2yjyVxfsDxXkC1l3fgnKWDGRNphZOgs",

  // Kontaktni podatki za zavihek Podpora
  SUPPORT_EMAIL: "info@rabimbox.si",
  SUPPORT_PHONE: "",
  BRAND_NAME: "Rabimbox",
};
