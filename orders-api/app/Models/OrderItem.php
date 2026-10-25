<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

class OrderItem extends Model
{
    protected $fillable = [
        'product_id',
        'product_name',
        'quantity',
        'unit_price_pence',
    ];

    public function order(): BelongsTo
    {
        return $this->belongsTo(Order::class);
    }
}
