import { type NextRequest, NextResponse } from "next/server";
import { createServerClient } from "@supabase/ssr";

export async function middleware(request: NextRequest) {
  const isMockMode =
    process.env.NEXT_PUBLIC_SUPABASE_URL?.includes("your-project.supabase.co") ||
    !process.env.NEXT_PUBLIC_SUPABASE_URL;

  let supabaseResponse = NextResponse.next({
    request,
  });

  const path = request.nextUrl.pathname;
  const isAuthPage = path.startsWith("/auth/login") || path.startsWith("/auth/register");
  const isOnboardingPage = path.startsWith("/auth/onboarding");
  const isLandingPage = path === "/";

  if (isMockMode) {
    const userCookie = request.cookies.get("active_user")?.value;
    if (!userCookie) {
      // Redirect unauthenticated requests to login page
      if (!isAuthPage && !isLandingPage) {
        const url = request.nextUrl.clone();
        url.pathname = "/auth/login";
        return NextResponse.redirect(url);
      }
    } else {
      // Direct authenticated users trying to hit login/register to dashboard
      if (isAuthPage) {
        const url = request.nextUrl.clone();
        url.pathname = "/dashboard";
        return NextResponse.redirect(url);
      }

      // Check workspace context
      const tenantId = request.cookies.get("active_tenant_id")?.value;
      if (!tenantId && !isOnboardingPage && !isLandingPage) {
        const url = request.nextUrl.clone();
        url.pathname = "/auth/onboarding";
        return NextResponse.redirect(url);
      }

      if (tenantId && isOnboardingPage) {
        const url = request.nextUrl.clone();
        url.pathname = "/dashboard";
        return NextResponse.redirect(url);
      }
    }
    return supabaseResponse;
  }

  // Real Supabase mode
  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll();
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value));
          supabaseResponse = NextResponse.next({
            request,
          });
          cookiesToSet.forEach(({ name, value, options }) =>
            supabaseResponse.cookies.set(name, value, options),
          );
        },
      },
    },
  );

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    if (!isAuthPage && !isLandingPage) {
      const url = request.nextUrl.clone();
      url.pathname = "/auth/login";
      return NextResponse.redirect(url);
    }
  } else {
    if (isAuthPage) {
      const url = request.nextUrl.clone();
      url.pathname = "/dashboard";
      return NextResponse.redirect(url);
    }

    const { data: memberships } = await supabase
      .from("tenant_memberships")
      .select("tenant_id")
      .limit(1);

    const hasTenant = memberships && memberships.length > 0;

    if (!hasTenant && !isOnboardingPage && !isLandingPage) {
      const url = request.nextUrl.clone();
      url.pathname = "/auth/onboarding";
      return NextResponse.redirect(url);
    }

    if (hasTenant && isOnboardingPage) {
      const url = request.nextUrl.clone();
      url.pathname = "/dashboard";
      return NextResponse.redirect(url);
    }
  }

  return supabaseResponse;
}

export const config = {
  matcher: [
    "/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)",
  ],
};
