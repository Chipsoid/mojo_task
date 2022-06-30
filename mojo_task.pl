=pod
Задача: вывести веб-страницу, которая покажет, на каких сайтах из топ-50 по России по версии SimilarWeb используется Яндекс.Метрика, а на каких Google.Аналитика.

Ограничения:
Страница должна рендериться быстро (<1s). Скорее всего, этого не получится достичь при синхронной реализации (когда запрос к веб-странице породит множество запросов внутри воркера, а ответы сразу же группируются к выдаче), поэтому тут от кандидата требуется подумать, как уложиться в данное требование.
Решение должно быть доступно в публичном репозитории на github/gitlab/bitbucket
Язык бэкенд части - Perl (5.26). Мы используем Mojolicious в качестве веб-фреймворка, Mojo::UserAgent в качестве юзер-агента, Mojo::DOM для парсинга страниц, Moo для ООП и MooX::Options в качестве основы для консольных скриптов. Будет здорово, если твоё решение тоже будет использовать какие-то из этих технологий (плюс они заметно могут облегчить написание, и для них есть много готовых кукбуков, например, https://metacpan.org/pod/distribution/Mojolicious/lib/Mojolicious/Guides/Cookbook.pod#Web-scraping или https://metacpan.org/pod/release/SRI/Mojolicious-8.58/lib/Mojolicious/Guides/Cookbook.pod#Backend-web-services).
Красота верстки фронтенда не имеет особого значения: она должна быть валидной и логичной и все.

Уточнения:
Есть большое количество аналогов similarweb (Рамблер.Топ, Alexa) - если какой-то из них представляет данные в более удобном формате/API,  можно использовать их вместо similarweb.
Во время рендеринга страницы можно обращаться к внутренней Базе Данных. Что это будет - SQL, NoSQL, файл (txt, tsv, json) - не важно, выбирай самый удобный для тебя вариант.
Для упрощения можно определять, что запросы на Яндекс.Метрику пойдут к домену mc.yandex.ru, а в Гугл.Аналитику к домену www.google-analytics.com
Нам приятно работать с кодом, соответствующим современным гайдлайнам стиля и структурирования для Perl программ (https://github.com/Perl/perl5/wiki/Defaults-for-v7). Прагмы use strict/use warnings должны быть обязательными, остальное (сигнатуры/...) - по желанию. Писать в функциональном стиле (map {} grep {} map {} … @list) тоже не стоит, так как это сильно ухудшает читабельность.
=cut

#!/usr/bin/env perl

use utf8;
use Modern::Perl;

use Mojolicious::Lite;
use Mojo::UserAgent;
use Mojo::Promise;


my @sites = ();
my $ua = Mojo::UserAgent->new;

$ua->max_redirects(3);
$ua->connect_timeout(20);
$ua->request_timeout(20);

# функция поиска счетчиков на странице
# просто ищет вхождения ключевых слов на странице.
# Возвращает ссылку на хэш с результатом проверок на оба счетчика
sub get_counter {
    my $content = shift;

    $content =~ s/\s+//g;

    my %answer = (
        'YM' => 0,
        'GA' => 0
    );

    $answer{'YM'} = 1 if $content =~ /mc.yandex.ru/ig;
    $answer{'GA'} = 1 if $content =~ /www.google-analytics.com/ig;

    return \%answer;
}

# Функция получения кода страницы
sub get_url_data {
    my $c = shift;
    return unless my $url = shift @sites;

    $ua->get_p($url)->then(sub {
        my ($tx) = @_;

        $c->send({ json => { 'url' => $url, 'data' => get_counter($tx->result->body) } });
        get_url_data($c);
    })->catch(sub {
        my ($err) = @_;
        # некоторые сайты недоступны из РФ, некоторые очень далеко территориально и загружаются долго
        # в таких случаях отправляем не информацию о счетчиках, а проблему по которой не получили информацию.
        # если ничего не отправлять – на сайте будут отображаться только успешные вызовы get_p
        $c->send({ json => { 'url' => $url, 'data' => $err } });
    });
}

any '/' => 'index';

websocket '/answer' => sub {
    my $c = shift;

    $c->inactivity_timeout(10);

    # Максимально быстро даём какой-то ответ по websocket, чтобы скорее получить первые данные (дать ответ code=101) и загрузка страницы была быстрее.
    $c->send({ json => { 'start' => 1 } });

    # Страницу с рейтингом предварительно сохранили в html, т.к. на самом сайте стоят защиты от ботов
    # Теоретически защиту можно обойти, если использовать javascript webbrowser PhantomJS, который можно замаскировать почти под настоящего пользователя.
    # Однако при первом входе попросили ввести captcha.
    # Поэтому здесь представлен мой способ получить перечень доменов из рейтинга, как если бы я мог получить эту страницу путем простого $ua->get()
    open(my $F, '<', 'similarweb.html');

    my $content = '';

    while (<$F>) {
        $content .= $_;
    }

    close ($F);

    $content =~ s/\s+//g;

    # Получаем список доменов из рейтинга, ссылки на домены имеют уникальный набор классов, поэтому по ним можно определить какие именно ссылки нам нужны со всей страницы
    # минусом такого подхода будет то, что при изменении ссылок на странице - паттерн перестанет работать
    # Не использовал Mojo::DOM чтобы не сильно усложнять или увеличивать код. В поиске счетчика аналогично.
    @sites = $content =~ m/<aclass="spritelinkouttopRankingGrid-blankLink"[^>]+?href=["']?([^'">]+?)['"].*?>/sig;

    my @promises;
    push @promises, get_url_data($c) for 1 .. scalar @sites;

    Mojo::Promise->all(@promises)->wait if @promises;
};

app->start;

__DATA__

@@ index.html.ep

<!DOCTYPE html>
<html lang="ru">
<head>
    <title>Поиск счётчиков на сайте из топ-50</title>
    <script src="//ajax.googleapis.com/ajax/libs/jquery/1.10.1/jquery.min.js"></script>
</head>
<body>
    <h1>Счётчики на сайтах из топ-50 SimilarWeb</h1>
    <p id="result"></p>
    %= javascript begin
    var ws = new WebSocket('<%= url_for('answer')->to_abs %>');
    ws.onmessage = function (e) {
        var res = JSON.parse(e.data);
        if ( typeof res.data.YM !== 'undefined' ) {
            $('#result').append(res.url);
            if ( res.data.YM == 1 ) 
                $('#result').append(' есть <b>Яндекс Метрика</b>');
            else if ( res.data.GA == 1 )
                $('#result').append(' есть <b>Google Analytics</b>');
            else if ( res.data.GA == 0 && res.data.YM == 0 )
                $('#result').append(' счётчики не найдены');
            $('#result').append('<br />');
        }
        else {
            $('#result').append(res.url + ' <b>error: ' + res.data + '</b><br />');
        }
    };
    % end
</body>
</html>