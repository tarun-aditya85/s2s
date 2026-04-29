import { Request, Response, NextFunction } from 'express';
import { TenantConfig } from '../types';

// In production, this would be loaded from a database
// For this boilerplate, we'll use environment variables or a config file
const TENANT_REGISTRY: Map<string, TenantConfig> = new Map();

/**
 * Initialize tenant registry
 * In production, load from database (PostgreSQL, DynamoDB, etc.)
 */
export function initializeTenantRegistry(tenants: TenantConfig[]): void {
  tenants.forEach((tenant) => {
    TENANT_REGISTRY.set(tenant.api_key, tenant);
  });
  console.log(`Loaded ${TENANT_REGISTRY.size} tenants into registry`);
}

/**
 * Load tenants from environment variable (JSON format)
 * Example: TENANTS='[{"tenant_id":"client_001","api_key":"sk_live_xxx","name":"Acme Corp","active":true}]'
 */
export function loadTenantsFromEnv(): void {
  const tenantsJson = process.env.TENANTS;
  if (!tenantsJson) {
    console.warn('No TENANTS environment variable found. Using demo tenant.');
    // Demo tenant for testing
    initializeTenantRegistry([
      {
        tenant_id: 'demo_tenant',
        api_key: 'sk_test_demo_key_12345',
        name: 'Demo Tenant',
        active: true,
        created_at: new Date(),
      },
    ]);
    return;
  }

  try {
    const tenants = JSON.parse(tenantsJson) as TenantConfig[];
    initializeTenantRegistry(tenants);
  } catch (error) {
    console.error('Failed to parse TENANTS environment variable:', error);
    throw new Error('Invalid TENANTS configuration');
  }
}

/**
 * Authentication middleware
 * Validates API key and attaches tenant_id to request
 */
export function authenticateRequest(
  req: Request,
  res: Response,
  next: NextFunction
): void {
  const apiKeyHeader = process.env.API_KEY_HEADER || 'X-API-Key';
  const apiKey = req.headers[apiKeyHeader.toLowerCase()] as string;

  if (!apiKey) {
    res.status(401).json({
      error: 'Unauthorized',
      message: `Missing ${apiKeyHeader} header`,
    });
    return;
  }

  const tenant = TENANT_REGISTRY.get(apiKey);

  if (!tenant) {
    res.status(401).json({
      error: 'Unauthorized',
      message: 'Invalid API key',
    });
    return;
  }

  if (!tenant.active) {
    res.status(403).json({
      error: 'Forbidden',
      message: 'Tenant account is inactive',
    });
    return;
  }

  // Attach tenant_id to request for downstream use
  (req as any).tenant_id = tenant.tenant_id;
  (req as any).tenant = tenant;

  next();
}

/**
 * Get tenant by ID (utility function)
 */
export function getTenantById(tenantId: string): TenantConfig | undefined {
  for (const tenant of TENANT_REGISTRY.values()) {
    if (tenant.tenant_id === tenantId) {
      return tenant;
    }
  }
  return undefined;
}

/**
 * Validate tenant exists and is active
 */
export function validateTenant(tenantId: string): boolean {
  const tenant = getTenantById(tenantId);
  return !!tenant && tenant.active;
}
