<?php

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;

class StoreOrderRequest extends FormRequest
{
    public function rules(): array
    {
        return [
            'customer_email' => ['nullable', 'email'],
            'items' => ['required', 'array', 'min:1', 'max:20'],
            'items.*.product_id' => ['required', 'string', 'distinct'],
            'items.*.quantity' => ['required', 'integer', 'min:1', 'max:10'],
        ];
    }
}
