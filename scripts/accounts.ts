// The six portal accounts, read from .env. Shared by the provisioning script
// and the isolation tests so both always agree on who is who.
import 'dotenv/config';

export type Role = 'owner' | 'analyst';
export type BrandSlug = 'kilele' | 'karoo' | 'marrakech';

export interface Account {
  brand: BrandSlug;
  role: Role;
  email: string;
  password: string;
}

function env(name: string): string {
  const v = process.env[name]?.trim();
  if (!v) throw new Error(`Missing ${name} in .env`);
  return v;
}

export function accounts(): Account[] {
  const brands: BrandSlug[] = ['kilele', 'karoo', 'marrakech'];
  const roles: Role[] = ['owner', 'analyst'];
  return brands.flatMap((brand) =>
    roles.map((role) => {
      const prefix = `${brand.toUpperCase()}_${role.toUpperCase()}`;
      return {
        brand,
        role,
        email: env(`${prefix}_EMAIL`).toLowerCase(),
        password: env(`${prefix}_PASSWORD`),
      };
    }),
  );
}

export function account(brand: BrandSlug, role: Role): Account {
  const a = accounts().find((x) => x.brand === brand && x.role === role);
  if (!a) throw new Error(`No account for ${brand}/${role}`);
  return a;
}
