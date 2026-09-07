import { PrismaClient, Decimal } from '@prisma/client'

const prisma = new PrismaClient()

// ── Chamada da Procedure 1.1 (cobrança) ──────────────────
// Prisma não tem suporte nativo a parâmetros OUT de procedures,
// então usamos $queryRaw com um SELECT após o CALL — padrão comum.
async function realizarCobranca(assinanteId: number, valor: number) {
  try {
    // Em PostgreSQL, CALL com OUT retorna uma linha com o parâmetro
    const result = await prisma.$queryRaw<[{ p_novo_saldo: Decimal }]>`
      CALL realizar_cobranca_mensal(${assinanteId}, ${valor}::NUMERIC, NULL)
    `
    console.log('Novo saldo:', result[0].p_novo_saldo)
    return result[0].p_novo_saldo
  } catch (error: any) {
    // O RAISE EXCEPTION do Postgres vira um erro com .message
    console.error('Erro na cobrança:', error.message)
    throw new Error(error.message)
  }
}

// ── Chamada da Procedure 1.2 (registrar reprodução) ──────
async function registrarReproducao(
  perfilId: number,
  videoId: number,
  ip: string,
  dispositivo: string
) {
  try {
    const result = await prisma.$queryRaw<[{ p_id_criado: BigInt }]>`
      CALL registrar_reproducao(
        ${perfilId}, ${videoId},
        ${ip}::INET,
        ${dispositivo},
        NULL
      )
    `
    return result[0].p_id_criado
  } catch (error: any) {
    throw new Error(error.message)
  }
}

// ── Chamada da Function 1.4 ───────────────────────────────
async function minutosAssistidos(produtoraId: number, competencia: string) {
  const result = await prisma.$queryRaw<[{ minutos_assistidos_por_produtora: Decimal }]>`
    SELECT minutos_assistidos_por_produtora(${produtoraId}, ${competencia}::DATE)
  `
  return result[0].minutos_assistidos_por_produtora
}

// ── Acesso via ORM (sem procedure) ───────────────────────
// Leitura normal de perfis de um assinante — o ORM lida com o JOIN
async function perfisDoAssinante(assinanteId: number) {
  return prisma.perfil.findMany({
    where: { assinanteId },
    include: {
      historicos: {
        where: { concluido: false },
        orderBy: { iniciadoEm: 'desc' },
        take: 5,
      },
    },
  })
}