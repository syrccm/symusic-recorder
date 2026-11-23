// 발사기(dispatcher.yml)를 10분마다 깨운다. GitHub 의 schedule 이 제때 돌지 않는 것을 보완한다.
const DISPATCH_URL =
  'https://api.github.com/repos/syrccm/symusic-recorder/actions/workflows/dispatcher.yml/dispatches';

export default {
  // 브라우저로 열어 살아 있는지 확인하는 용도.
  async fetch() {
    return new Response('ok');
  },

  async scheduled(_controller, env) {
    const res = await fetch(DISPATCH_URL, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.GH_PAT}`,
        Accept: 'application/vnd.github+json',
        'User-Agent': 'symusic-recorder-wake',
      },
      body: JSON.stringify({ ref: 'main' }),
    });
    if (res.status !== 204) {
      const body = await res.text();
      console.error(`dispatcher 실행 요청 실패: HTTP ${res.status} ${body.slice(0, 200)}`);
    }
  },
};
