# Indicação Premiada Evolua Academy

Aplicação web responsiva em React + Vite + Supabase. A interface usa a logo enviada da Evolua Academy e a paleta roxa, preta, branca e violeta.

## Estrutura
- `public/`: logo oficial e recursos estáticos.
- `src/`: interface React, páginas, componentes e conexão Supabase.
- `supabase/migrations/`: SQL versionado das mudanças do banco.
- `supabase/functions/`: funções protegidas de sorteio, emissão manual e processamento de matrículas elegíveis.
- `supabase/SETUP_COMPLEMENTAR.sql`: arquivo único que reúne as migrações complementares para aplicar no projeto Supabase já existente.
- `docs/`: regras do produto e checklist de validação.

## Funcionalidades implementadas na aplicação
- Cadastro por e-mail/senha com nome e WhatsApp.
- Login por e-mail/senha e fluxo preparado para Google OAuth.
- Recuperação de senha por e-mail.
- Área do participante: campanhas, cadastro de indicações, tickets, histórico e revelação visual do prêmio.
- Área administrativa protegida por `profiles.role = 'admin'`.
- Criar, editar, ativar, pausar e encerrar campanhas; excluir rascunhos sem dados relacionados; enviar banners.
- Criar prêmios com imagem, categoria, peso, estoque e indicação de prêmio de consolação; pausar/ativar prêmios e aumentar estoque/peso.
- Atualizar status dos leads e criar matrícula pendente quando uma indicação é marcada como matriculada.
- Confirmar matrícula manualmente, respeitar a janela de 7 dias e cancelar antes da emissão.
- Liberação manual de tickets para um participante.
- Função de sorteio transacional, ticket de uso único, registro do resultado e controle de estoque.
- SQL de processamento automático de matrículas elegíveis e regressão de nível via `pg_cron`.

## Configuração local
1. Instale Node.js LTS.
2. Extraia o ZIP e abra a pasta no terminal.
3. Copie `.env.example` para `.env`. A URL do projeto e a chave publicável fornecidas já estão preenchidas como ponto de partida.
4. Execute `npm install` e `npm run dev`.
5. Para validar a compilação, execute `npm run build`.

## Supabase já existente
O banco base já foi criado no projeto `axxbxptgdjypksjjpytn`. Antes de aplicar mudanças, faça backup e confirme que as tabelas base `profiles`, `campaigns`, `prizes`, `leads`, `enrollments`, `tickets`, `draws` e `audit_logs` existem.

Para aplicar as alterações complementares, abra o SQL Editor do Supabase e execute `supabase/SETUP_COMPLEMENTAR.sql` **uma única vez**. Não execute esse arquivo e todas as migrações individuais em duplicidade. A migração ativa Storage, função transacional de sorteio, emissão manual, emissão após 7 dias e agendamento de regressão de nível. Se `pg_cron` não estiver habilitado no projeto, ative-o em Database → Extensions e execute o arquivo novamente após verificar o estado das migrações.

## Edge Functions
Depois de aplicar o SQL, publique as funções da pasta `supabase/functions/` no projeto Supabase. Com o Supabase CLI instalado e autenticado, execute na raiz do projeto:

```bash
supabase link --project-ref axxbxptgdjypksjjpytn
supabase functions deploy draw-prize
supabase functions deploy issue-ticket
supabase functions deploy process-eligible-enrollments
```

As funções usam as variáveis de ambiente gerenciadas pelo Supabase. Nunca coloque `service_role`, `sb_secret_...`, senhas ou tokens privados no frontend ou no GitHub.

## Google OAuth e e-mail
No Supabase, configure Authentication → Providers → Google com as credenciais OAuth do projeto. Em Authentication → URL Configuration, inclua o domínio final do site e os caminhos de retorno usados pelo login e recuperação de senha. A configuração do provedor Google depende das credenciais de OAuth da conta/projeto da escola.

## Publicação recomendada: Cloudflare Pages
- Build command: `npm run build`
- Output directory: `dist`
- Variáveis de ambiente de produção: `VITE_SUPABASE_URL` e `VITE_SUPABASE_PUBLISHABLE_KEY`.
- Publique o repositório `indicacao-premiada-evolua` e configure o domínio/URL final no Supabase Auth.

## Regras importantes
- Uma indicação só vira matrícula quando a equipe confirmar a matrícula e o pagamento. O ticket só é liberado após 7 dias, desde que não haja cancelamento.
- Cada matrícula pode gerar a quantidade de tickets definida em `ticket_quantity`; o banco registra `tickets_issued_at` para impedir emissão duplicada.
- Os níveis são Explorador (1–5), Conquistador (6–14) e Elite (15+), usando o histórico acumulado de matrículas válidas. Após 30 dias sem nova matrícula válida, o agendador reduz no máximo um nível por ciclo de 30 dias.
- Para que cada ticket tenha um prêmio, cada campanha ativa precisa ter estoque disponível de prêmios regulares para os níveis e estoque de consolação suficiente para cobrir os tickets disponíveis e os novos tickets liberados. O backend nunca inventa prêmio nem permite estoque negativo; se o estoque estiver insuficiente, a emissão é bloqueada até a reposição.
- A animação apenas revela o prêmio já escolhido pelo banco. O navegador não decide o resultado.

## Estado de validação
A sintaxe dos arquivos JSX/JavaScript foi verificada. A instalação de dependências e o build completo não puderam ser concluídos neste ambiente por timeout de rede. Antes de lançar publicamente, execute `npm install` e `npm run build`, aplique o SQL no projeto correto, publique as Edge Functions e teste com as duas contas administradoras e uma conta de participante. Verifique RLS, Google OAuth, e-mail de recuperação, upload, concorrência do sorteio e jobs do `pg_cron`.
