<?php

use Illuminate\Support\Facades\Route;

Route::get('/', fn () => ['service' => 'orders-api']);
