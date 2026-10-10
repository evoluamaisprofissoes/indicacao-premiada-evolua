# Requisitos funcionais e checklist de aceite

## Campanhas
- Cada campanha tem banner, descrição, período, status e catálogo de prêmios isolados.
- Campanhas podem coexistir sem misturar tickets nem resultados.
- Antes de ativar, revisar regulamento, estoque, pesos de probabilidade e prêmios disponíveis.

## Indicações e matrícula
- O participante registra nome, WhatsApp, curso de interesse e campanha.
- Equipe acompanha status: novo, em contato, matriculado ou não convertido.
- Matrícula só é válida após confirmação de pagamento e janela de cancelamento de 7 dias.
- Impedir duplicidade de tickets por matrícula, mas permitir que uma matrícula conceda mais de um ticket quando a regra da campanha permitir.

## Níveis
- Explorador: 1 a 5 matrículas válidas.
- Conquistador: 6 a 14.
- Elite: 15 ou mais.
- Guardar histórico acumulado separado do nível atual.
- Sem matrícula válida por 30 dias: regredir no máximo um nível por ciclo de 30 dias, sem apagar o histórico.
- Definir e testar como a regressão interage com níveis baseados no total histórico.

## Sorteio
- Todo ticket disponível participa de uma campanha e pode ser utilizado uma única vez.
- Sorteio deve ocorrer no backend com transação/locks para evitar estoque negativo e duplicidade.
- Cada sorteio grava ticket, usuário, campanha, prêmio e snapshot do prêmio.
- Prêmios devem respeitar peso relativo, nível elegível, estoque e regra de prêmio de consolação.
- Interface de caixa-surpresa deve revelar a resposta do backend, com som opcional, animação e confete. Animação nunca decide o prêmio.

## Administração
- Administradores: conta pessoal e conta da escola, ambas com role admin.
- Gerenciar campanhas e banners.
- Gerenciar catálogo, imagem, estoque e pesos dos prêmios.
- Consultar e atualizar leads.
- Confirmar matrícula e liberar tickets manualmente.
- Ver histórico e auditoria.
- Ações privilegiadas exigem verificação server-side de role.

## Segurança
- RLS em todas as tabelas expostas.
- Nunca expor service-role/secret key no frontend.
- Uploads limitados por tipo/tamanho e restritos a admins.
- Testar com admin pessoal, admin escola e participante comum.
